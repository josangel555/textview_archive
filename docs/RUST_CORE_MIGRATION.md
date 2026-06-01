# Rust Core Migration — the forward plan

> **Status: forward-reference, not in flight.** The Rust core is *deferred* —
> the owner is deliberately leaving the Core alone until the real migration
> begins. This doc consolidates the locked decisions, phases the migration, and
> describes the end-state the SwiftUI app converges to, so that whoever starts
> the migration starts from a single map rather than re-deriving it. It is
> **documentation only**; no Rust/Core code exists in this repo yet beyond the
> throwaway PoC (which lives on a separate branch and is not on `main`).
>
> **Grounding (read these first, in this order):**
> 1. `archive/RUST_CORE_PLAYBOOK_2026-05-30.md` — the production-grade Rust
>    playbook (workspace layout, dep shortlist, sans-IO architecture, lints,
>    CI). The *how-to-build-it* reference. **§10 holds the still-open calls.**
> 2. `archive/RUST_DEPENDENCY_AND_SIZING_2026-05-31.md` — measured dep
>    blast-radius + bundle sizing. The *what-it-costs* reference.
> 3. `docs/POC_STAGE0-2_OUTCOME_2026-05-31.md` — the Stage 0–2 PoC that
>    **validated the split end-to-end** (it worked, and beat Swift on perf).
>    The *it-actually-works* evidence.
> 4. `docs/RUST_CORE_TESTING.md` — the companion: how the core + every
>    front-end gets tested once the migration happens. Cross-linked throughout.
> 5. `DESIGN.md` §3 (module boundaries) and `docs/HANDOFF_2026-05-31.md` §2
>    (the pivot + locked decisions) — current Swift layering and the decision log.

---

## 0. One-paragraph orientation

Today the app is `ViewerKit ← ViewerCore (SwiftUI-free) ← ViewerUI ← MarkdownViewer`
— three Swift packages plus a thin `.app` target. The migration moves the
**domain/state logic** that currently lives in `ViewerCore` (and some of the
`@MainActor` state machines in `ViewerUI`) *down and out* into a headless Rust
core reached over a C ABI. The SwiftUI app does not get rewritten; it gets
**thinned** into a projection layer over the FFI. The same Rust core later
backs a TUI and a vanilla-web front-end with **no new core code** — that
"one core, three projections" payoff is the entire point, and the PoC proved the
mechanism is sound and (surprisingly) faster than the incumbent Swift path even
paying full FFI + serialization tax.

---

## 1. The locked decisions (consolidated)

These are **decided**, recorded in the `project_rust_core_decision` memory note
and `docs/HANDOFF_2026-05-31.md` §2, refined by the dep/sizing study and the
PoC. They are not up for re-litigation at migration time — only their
*application* is.

| # | Decision | Locked choice | Why / where validated |
|---|---|---|---|
| 1 | **Core language** | **Rust** | Reusable, compact, safe; `#![forbid(unsafe_code)]` core with a quarantined unsafe edge. |
| 2 | **Core shape** | **Sync, sans-IO functional core** — `&mut self` state machine, time/RNG injected, effects returned as data, level-triggered snapshots | Every reference project (quinn-proto, Crux, Firezone) + the xi-editor post-mortem converge here. Easiest possible thing to test deterministically (see testing doc §1). |
| 3 | **FFI mechanism** | **Hand-written `extern "C"` + `cbindgen`, in a separate crate** — NOT uniffi, NOT swift-bridge | PoC built it: 7 extern fns, one guard macro, opaque handles. One small C surface serves Swift *and* the future WASM/remote front-ends; no generated unsafe to audit; keeps the core sync. uniffi double-serializes (`RustBuffer`); swift-bridge is bus-factor-1/pre-1.0 and lacks slice/`Box<T>` support. |
| 4 | **Doc text crossing** | **Opaque handle, never by value** | The core owns the document; Swift holds a `SessionHandle` (forward-declared opaque struct — Swift can't fabricate one). Structured results cross as a serialized frame, not as `#[repr(C)]` structs. |
| 5 | **Cross-language wire** | **`rmp-serde` (MessagePack), `to_vec_named()`** | Only serde-native option with mature Swift + browser-JS decoders. `to_vec_named` forces **maps** (named fields) so the core can evolve its types without breaking the C ABI. **`postcard` DROPPED** — its "tiny" reputation is `no_std`/embedded; on a host it drags `heapless`+`cobs` (15 deps vs rmp-serde's 5). |
| 6 | **Framing** | **DIY `u32`-LE length prefix + own RPC dispatch** | Hand-rolled, tested in the PoC (oversized/truncated/short frames rejected). tarpc/capnp-rpc/tonic all force async + drag runtimes; none have a Swift impl. |
| 7 | **Crash reporting** | **DIY** | No third-party crash SDK. `catch_unwind` at every FFI entry for *host survival* (see §6 — it's survival, not soundness, since Rust 1.81). |
| 8 | **Telemetry / observability** | **DIY** — a `tracing`-shaped `Sink` facade in-core | PoC wired a hand-rolled `Sink` into `csv.parse`/`session.*` spans. Real `tracing` is a one-line `cargo add` later if wanted; the seam is already shaped for it. |
| 9 | **Adopt (DIY = false economy)** | tree-sitter, **comrak (`default-features=false`!)**, notify, tracing, serde, rustls (remote tier only) | Each is a parsing/watching/crypto tarpit. comrak's 67-dep default is a CLI+syntect illusion; `default-features=false` → 13 pure-Rust crates, zero C. |
| 10 | **Roll our own** | sync reducer, wire framing, RPC dispatch, level-triggered push engine, error layers, channels | The functional-core machinery is the product's spine; owning it keeps the dep surface tiny and the core deterministic. |
| 11 | **Large-file editing** | **Deferred** (`ropey` later, only if real in-place GB editing is needed) | Viewer-first; don't pay the rope tax preemptively. |
| 12 | **FFI panic strategy** | **`panic=unwind` + `catch_unwind` for the macOS GUI**; `abort` acceptable for supervised headless Linux/WASM | The shipping macOS dylib must link the **`dist`/unwind** profile, NOT `release`/abort — easy to get wrong by reflex (PoC §6). |

**Still genuinely open** (do not pre-decide; spike at migration time): the LSP
async route (hand-rolled sync framing vs a contained tokio I/O thread), and
whether mmap ever gets quarantined into a leaf crate. Both are tracked in the
playbook §10 as **soft / no one-way-door** decisions. See §5 below.

---

## 2. Where the seam already is (so the migration has something to grab)

The migration is tractable *because the Swift app is already layered for it.*
The seams the core slots into already exist and are exercised by tests:

```
  ┌─────────────────────────────── TODAY ────────────────────────────────┐
  │  MarkdownViewer (.app)   AppDelegate, NSDocumentController, services    │
  │            │                                                            │
  │  ViewerUI  │  SwiftUI views + AppKit glue + DocumentModel (@MainActor   │
  │            │  ObservableObject) + EditorCoordinator + AutomationHost    │
  │            ▼                                                            │
  │  ViewerCore (SwiftUI-FREE)  markdown→HTML, file watch, history, git,    │
  │            │                Claude parser, FindEngine, CMBridgeCodec…   │
  │            ▼                                                            │
  │  ViewerKit  protocols, models, pure data types (HighlightSpan, …)       │
  └────────────────────────────────────────────────────────────────────────┘
```

Three existing facts make this a *thinning*, not a *rewrite*:

- **`ViewerCore` is already SwiftUI-free and fully unit-testable.** ~80% of
  behavior lives below the view layer and runs without a display (DESIGN.md §3).
  That is precisely the code that migrates first.
- **`DocumentModel` is a DI-constructable `@MainActor ObservableObject`** with an
  `EditorCoordinator`, and it already conforms to **`AutomationHost`** —
  `automationCurrentState() -> AutomationState` returns a serializable snapshot
  of the whole app state. That snapshot shape is the natural template for what
  the core's level-triggered `subscription_snapshot` will return.
- **The "fake the other end" pattern is already in the tree.**
  `Sources/MDVFakeLSPServer` is a deterministic out-of-process server the host
  tests drive. The same pattern — fake the binary-RPC peer — is how each
  front-end will test its half of the FFI in isolation (testing doc §3).

So the core does not invent a new architecture; it **inherits the boundary
`ViewerCore`/`ViewerKit` already drew** and pushes it across a process/FFI line.

---

## 3. Phasing — what moves, and in what order

The PoC's central finding drives the order: **pure logic with a clean
input→output shape is the cleanest entry; stateful sessions are next; the
I/O-entangled and view-coupled bits are last (or never).** Move capability by
capability, each behind its own opaque handle, each landing with the FFI-boundary
tests from the testing doc before the Swift side switches over to it.

### Phase A — Pure, stateless logic (the beachhead)

The PoC validated this exact shape with CSV: hand-rolled parse → `Table` →
MessagePack frame → Swift decode, with **correctness parity vs the Swift
incumbent** and a **perf win end-to-end**. Generalize from CSV to the rest of
the pure transforms.

- **First movers:** CSV/TSV parse + filter (PoC-proven), hex/binary formatting,
  the markdown→HTML render (`MarkdownToHTML`/comrak `default-features=false` +
  tree-sitter highlight spans), find/search over a buffer (`FindEngine`),
  diff computation, the `CMBridgeCodec`/`CMEditApplier` JS-batch codec.
- **Shape:** stateless `fn(input bytes) -> Result<frame, WireError>`. No handle
  needed for the truly stateless ones; a handle the moment state is retained.
- **Swift side:** `ViewerCore`'s Swift impl stays in place as a *fallback and
  parity oracle* during the phase. Each transform gets an A/B parity test
  (Rust output == Swift output across shared inputs) before the Swift impl is
  retired. This is exactly the PoC's "10 shared inputs" parity harness, scaled.
- **Exit criterion:** the pure transforms run through the core, parity tests
  green, the Swift duplicates deleted.

### Phase B — Stateful sessions (the PoC's Stage 2)

The PoC built a `CsvSession` that owns table+filter, bumps a version on
`set_filter`, and emits a **level-triggered** `snapshot()` (full current visible
state, not deltas — proven by `snapshot_is_level_triggered_full_state`). That is
the template for every stateful document the core will own.

- **Movers:** the per-document state machines — open/filter/scroll/selection
  state, the editor buffer + edit/undo history, code-folding state, the
  walkthrough/sessions state, git-status-per-tab.
- **Shape:** `open → ... mutating ops ... → snapshot → free`, the sans-IO
  quartet (`handle_input` / `handle_timeout` / `poll_effect` / `poll_timeout`),
  level-triggered snapshots. Time and RNG injected, never read ambiently.
- **Swift side:** `DocumentModel`/`EditorCoordinator` stop *owning* this state
  and start *projecting* the core's snapshot. The `@Published` properties become
  views derived from the latest snapshot frame (see §4). ARC drives handle
  lifetime — the PoC's `final class CsvSession { deinit { poc_session_free(...) } }`
  pattern, where `deinit` frees the Rust handle exactly once.
- **Exit criterion:** `DocumentModel` holds *no* domain state of its own — only
  a handle + the last decoded snapshot + view concerns (focus, AppKit refs).

### Phase C — The I/O-entangled edges (contained, not in the pure core)

These keep their real I/O in the *imperative shell* (per front-end), surfacing
only results into the core as events. They migrate last because they're where
async/threading lives and where the one genuinely-open decision sits.

- **File read/write/atomic-save/fsync** — blocking std syscalls on a worker
  pool. The four-step atomic-durable-save (temp-same-dir → `write_all` →
  `sync_data` → `rename` → parent-dir fsync) is owned by one tested function in
  the core's effect-execution layer. (Playbook §5.)
- **File watching** (`notify`) — its own thread, delivers via channel, feeds the
  subscription system. Core stays sync. Always re-stat on event (notify is not
  ground truth).
- **git / jq (batch)** — one reader + one writer thread per child, channels into
  the core. Fully sync, zero async deps.
- **LSP JSON-RPC** — **the one honest async conflict.** Decide by spike (§5):
  hand-rolled sync framing + request-id→oneshot map, *or* a single contained
  tokio runtime on a dedicated I/O thread exposed to the core only via channels.
  Either way, results enter the core as **events**, never the protocol itself.
- **Remote transport** (WebSocket, `tungstenite` + `rustls`) — lives in a
  `textview-remote` crate behind the same channel wall. Only the remote tier.

### Phase D — What stays Swift, permanently

These never move. The core is headless by design; the host owns the screen.

- **The AppKit shell** — `AppDelegate`, `NSDocumentController`, services
  registration, `NSWindow`, menus, the `NSEvent`→action chain.
- **`WKWebView`** and the entire rendered-markdown/mermaid/CM6 web layer
  (the 4.2 MB JS — it does not cross to the core; it's a UI asset).
- **The SwiftUI/AppKit view layer** — `ContentView`, `TabBar`, `Sidebar`,
  `StatusBar`, the `NSViewRepresentable` wrappers, the source `NSTextView`.
- **The thin projection glue** — `DocumentModel`/`EditorCoordinator` survive,
  but as projection drivers (§4), not state owners.

```
  capability                       Phase   moves to core?   notes
  ───────────────────────────────  ─────   ──────────────   ──────────────────────────
  CSV/TSV parse+filter             A       ✅ (PoC-proven)  beachhead, perf win
  markdown→HTML + highlight spans  A       ✅               comrak no-default + tree-sitter
  find / diff / hex / CM codec     A       ✅               stateless transforms
  per-doc session state            B       ✅               opaque handle, level-trig snapshot
  editor buffer + undo history     B       ✅               sans-IO quartet
  file read/write/atomic-save      C       ✅ (shell I/O)   effect executed in shell
  file watching (notify)           C       ✅ (shell I/O)   thread→channel→subscription
  git / jq batch                   C       ✅ (shell I/O)   reader+writer threads
  LSP JSON-RPC                     C       ✅ (contained)   OPEN: sync vs tokio-thread (§5)
  remote / WebSocket               C       ✅ (remote tier) tungstenite+rustls, async island
  AppKit shell / NSWindow / menus  D       ❌ stays Swift   the host owns the screen
  WKWebView + CM6/mermaid JS       D       ❌ stays Swift   UI asset, never crosses
  SwiftUI view layer               D       ❌ stays Swift   projection of core snapshots
```

---

## 4. How the SwiftUI app becomes a thin projection

The end-state: **`DocumentModel` stops being a state machine and becomes a
`CoreClient` projection.** It holds an opaque handle and the last decoded
snapshot; its `@Published` properties are *derived* from that snapshot; user
actions are *forwarded* as core inputs; the core's level-triggered snapshot is
*reconciled* into the published state (Kubernetes-style — resend current state,
client reconciles; deltas would unrecoverably desync on a dropped link).

```
  user action (SwiftUI)                       core snapshot (MessagePack frame)
        │                                                    ▲
        ▼                                                    │
  DocumentModel.dispatch(action) ──encode──▶ CoreClient.send │
        │                                          │         │
        │                            ┌─────────────┘         │
        │                            ▼                       │
        │                   ┌──────────────────┐             │
        │                   │  TRANSPORT TIER  │  (one of three, swappable)
        │                   └──────────────────┘             │
        ▼                            │                        │
  @Published vm  ◀──reconcile────────┴── decode snapshot ─────┘
  (SwiftUI re-renders the projection — no domain logic on the Swift side)
```

**The three transport tiers** — same `CoreClient` API, swappable behind it.
This is what the "effects as data, not callbacks" decision buys: the core
returns an effect/snapshot as data, so the *same* core runs locally or ships
over a wire with zero core changes.

| Tier | Transport | Use | Cost |
|---|---|---|---|
| **In-proc** | Direct FFI call into the linked `.dylib` (the PoC's path) | The shipping macOS app, the TUI | Lowest latency; one `lipo`'d universal dylib in the bundle. **This is the default.** |
| **UDS** | Length-prefixed MessagePack over a Unix domain socket to a local core process | Multi-window sharing one core; a core that outlives a crashing UI; sandboxing the core | Process boundary, same machine; the framing is the PoC's `u32`-LE + rmp. |
| **Remote** | Same framing over WebSocket (`tungstenite`+`rustls`) | A thin Mac UI driving a core on another machine; the browser front-end | Network latency + TLS; lives in `textview-remote`. |

The projection code is **transport-agnostic**: `DocumentModel` talks to
`CoreClient`, which talks to one of the three tiers. The wire format (rmp-serde
named maps) is identical across all three — only the byte-pipe differs. The PoC
proved the in-proc tier end-to-end (FFI open + parse + encode + Swift decode);
the UDS and remote tiers reuse the exact same framing over a different pipe.

**What the Swift side keeps:** the `@Published`/`ObservableObject` reactivity (so
SwiftUI re-renders), focus/selection that is genuinely a *view* concern, AppKit
object references, and the `AutomationHost` surface (which now reads the core's
snapshot instead of Swift-side state). What it sheds: every line of
parse/filter/search/diff/history/git logic — that's all core now.

---

## 5. One-way-door risks, and how the PoC de-risked them

The reason the migration is *deferred but not feared* is that the PoC
deliberately attacked the irreversible-mistake class first. Status per risk:

| Risk | Why it's a door | PoC verdict |
|---|---|---|
| **Panic across the FFI boundary** | A panic unwinding into C is UB on old Rust → silent corruption | **De-risked.** Every extern body wrapped (`ffi_guard!`/`catch_unwind`); panic→`.panic` error mapping proven by a Swift test. **Correction the PoC found:** since Rust 1.81 an unwind across `extern "C"` is *defined* (auto-aborts), so `catch_unwind` is for **host survival**, not soundness. The playbook's "panic is UB" line is stale. |
| **Handle lifecycle / double-free / leak** | Free-on-wrong-side or missed-free is unrecoverable in a long-lived app | **De-risked.** `Box::into_raw`/`from_raw` + explicit `poc_session_free`; ARC `deinit` frees exactly once; opaque forward-declared handle (Swift can't fabricate one). Tested null-free, double-free, 1000-iter lifecycle loop. |
| **Threading / single-writer violation** | Concurrent `&mut self` into the core = data race = UB | **De-risked.** `Mutex`-wrapped handle, `try_lock`→`Busy` makes a violation *loud*; justified `unsafe impl Send+Sync`; proven by `concurrent_calls_are_serialized_or_rejected_never_ub` (8 threads × 200 ops). Poisoned-mutex recovery so one panic doesn't wedge the handle. |
| **Wire format pinning the ABI** | If structs cross by `#[repr(C)]`, every core type change breaks the C ABI | **De-risked by design.** Only the small status enum + handle pointers are ABI-frozen; everything structured crosses as rmp-serde **named maps**, so the core evolves its types freely. The stability line is drawn at the right place. |
| **Cross-platform packaging** | Single-host arm64 is fine for a PoC; shipping needs universal + iOS | **NOT yet de-risked — known gap.** PoC is arm64-only with a hard-coded `-L`/`-l` link path. The `lipo` universal + `xcframework` `binaryTarget` is *designed but unbuilt* (x86_64 target not installed under the no-install rule). **This is the single biggest PoC→shippable gap** and the gate for the "core is the product / cross-platform" direction. First real migration task. |
| **LSP async coloring the core** | One async lib drags tokio into the whole binary; function-color is viral | **Deliberately left open** (playbook §10.3). Decide by spiking the sync hand-roll's complexity on a real server (rust-analyzer), not by reading. Feature-gated either way so it can't infect WASM/TUI builds. Soft door. |
| **mmap vs `forbid(unsafe_code)`** | They're literally incompatible | **Deliberately deferred.** Default to safe `seek`+buffered reads; quarantine mmap into a leaf crate *only if profiling demands it*. No door — purely additive later. |

The honest read from the PoC: **FFI friction is real but front-loaded and
bounded** — one crate, 7 extern fns, a guard macro, an opaque-handle module.
Once the boundary patterns are set, adding a new core call is mechanical. The
friction is a one-time tax, not a per-feature tax. Two caveats before banking
the perf headline (PoC §1): (a) the A/B compared Rust full-pipeline against
Swift *parse-only*, not parse+filter+project; (b) packaging is single-host
arm64-only.

---

## 6. The per-front-end roadmap

"One core, three projections." The macOS app comes first because it exists;
the others are unlocked *for free* by the headless core, each shedding the UI
assets it doesn't need (dep/sizing doc §2).

```
                          ┌──────────────────────────┐
                          │   Rust core (headless)    │  ← all domain/state logic
                          │   sans-IO, sync, tested   │     (cargo test, shared base)
                          └────────────┬──────────────┘
              in-proc / UDS / remote — same rmp-serde wire
        ┌──────────────────┬───────────┴───────────┬──────────────────┐
        ▼                  ▼                       ▼                  ▼
  ┌───────────┐     ┌─────────────┐         ┌─────────────┐    ┌─────────────┐
  │ SwiftUI   │     │ TUI         │         │ vanilla-web │    │ headless    │
  │ macOS app │     │ (ratatui)   │         │ (WASM)      │    │ Linux server│
  │  NOW      │     │  LATER      │         │  LATER      │    │  LATER      │
  └───────────┘     └─────────────┘         └─────────────┘    └─────────────┘
   ~36 MB            ~2–20 MB                ~1–2 MB wasm        ~5–20 MB static
   (size wash)       (sheds 4.2MB JS)        + 4.2 MB JS         (+rustls)
```

- **SwiftUI (now).** The thinning described in §4. Size is a *wash* — the Swift
  exec shrinks roughly as much as the Rust dylib (~0.3–3 MB) adds; the real
  20 MB (grammars + JS) doesn't move. SwiftUI/AppKit cost 0 bundle bytes.
- **TUI (later, ratatui).** In-proc tier, no WKWebView → sheds the 4.2 MB JS.
  ~2–4 MB without highlighting, ~17–20 MB with the grammars. The core's snapshot
  projects into a ratatui `Buffer` cell-grid. Testing: `Buffer` assertions +
  vt100 oracle (testing doc §2).
- **Vanilla-web (later, WASM).** Sub-MB core code post `wasm-opt -Oz` (native-only
  deps — notify/memmap2/rustls/subprocess — don't cross to wasm; they stay
  server-side). Reuses the 4.2 MB JS as a UI asset. Either in-proc-via-wasm or
  remote tier to a server core. Testing: jsdom L2 + a `--headless=new`
  computed-style/Playwright lane for the layout cliff (testing doc §2).
- **Headless Linux server (later).** The remote tier's other end: a static
  binary (+rustls ~1–3 MB) speaking the WebSocket transport to thin UIs.

---

## 7. Migration sequencing (the concrete first moves)

Ordered for maximum de-risking per unit effort, assuming the owner has greenlit
the migration:

1. **Stand up the workspace from the playbook** (§2 layout): flat `crates/`,
   `textview-core` (`forbid(unsafe_code)`), `textview-proto`, `textview-ffi`
   (the only unsafe crate), pinned `rust-toolchain.toml`, `deny.toml` on commit
   #1, the `[workspace.lints]` block. Start dependency-empty; every `cargo add`
   is a reviewable event (playbook §10.10).
2. **Close the cross-platform packaging gap** (the one un-de-risked door, §5):
   `x86_64-apple-darwin` slice + `lipo` universal + `xcframework` `binaryTarget`,
   switching `Package.swift` off the PoC's `unsafeFlags` link hack. This is the
   PoC→shippable gate.
3. **Port the PoC's CSV beachhead onto the real workspace** and wire the
   FFI-boundary test suite (testing doc §3) as a hard CI gate.
4. **Phase A** — migrate the pure transforms behind parity tests, retire the
   Swift duplicates as each goes green.
5. **Phase B** — convert `DocumentModel`/`EditorCoordinator` to the `CoreClient`
   projection; move stateful session logic into the core behind handles.
6. **Phase C** — bring the I/O edges across into the imperative shell; spike the
   LSP async route and decide it (§5).
7. **Unlock the other front-ends** — TUI first (in-proc, no new core code),
   then WASM/web, then the remote/server tier.

Each step lands with its tests green before the Swift fallback is deleted — the
parity oracle is the safety net that makes the migration reversible step by step.

---

## 8. Cross-references

- **`docs/RUST_CORE_TESTING.md`** — the companion testing doc: L1 `cargo test`
  as the shared base, the FFI-boundary tests the PoC established, and the
  per-front-end projection tiers. **Read it alongside this doc.**
- **`archive/RUST_CORE_PLAYBOOK_2026-05-30.md`** — workspace layout (§2), dep
  shortlist (§3), sans-IO architecture (§4), per-domain gotchas (§5), build/
  packaging (§7), lints/CI (§8), **open decisions (§10)**.
- **`archive/RUST_DEPENDENCY_AND_SIZING_2026-05-31.md`** — measured dep
  blast-radius + per-target bundle sizing.
- **`docs/POC_STAGE0-2_OUTCOME_2026-05-31.md`** — the validating PoC; foundations
  scorecard (§3), measurements (§4), product-identity read (§5), risks/gotchas
  incl. the panic-UB correction (§6), next steps (§7).
- **`DESIGN.md`** §3 — current Swift module boundaries.
- **`docs/HANDOFF_2026-05-31.md`** §2 — the pivot + the locked-decision log.
