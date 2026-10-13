# Rust migration plan — consolidated roadmap (2026-06-13)

> **Status: SPIKE deliverable for TSK-775.** Spike + design auto-approved
> (owner 2026-06-13). This consolidates the piecemeal artifacts — the prior
> execution plan (`docs/RUST_MIGRATION_PLAN_2026-06-04.md`), the 9-agent
> rust-core audit (`docs/research/rust-core-audit-2026-06-09/synthesis.md`,
> epic TSK-538), the per-engine port tickets (TSK-630/631/632/633), the
> thin-waist FFI envelope (TSK-580), the remote-core epic (TSK-651) and its
> shipped pieces (TSK-652/655/658/660/662/665), and the migration policy — into
> one current top-level picture.
>
> **The headline that reframes everything:** the migration is *much* further
> along than the TSK-775 framing implies. The four "approved-but-pending" engine
> ports are all **validated and shipping default-ON**, every stateless capability
> now routes through Rust by default (Stage A complete), the thin-waist envelope
> is the production dispatch path, and a working remote `mdv-serve` daemon + Swift
> `RemoteTransport` already exist. **This plan is a finishing plan, not a
> greenfield plan.** The open work is: (a) finish two in-flight contract slices,
> (b) the owner-gated Swift-twin deletion, (c) the stateful (CSV-session / DocId)
> tier, and (d) hardening lanes. No new engine ports are pending.

---

## 1. Current state — what's in Rust vs Swift

### 1.1 The workspace (`rust-core/`)

Six crates; the merge gate (`scripts/rust-core-gate.sh`) and the Swift staticlib
build operate only on `default-members = [core, ffi, serve]`:

| Crate | Role | Posture |
|---|---|---|
| `mdvcore-core` | The pure, **sans-IO**, `#![forbid(unsafe_code)]` functional core — every engine + `wire` (MessagePack framing) + `dispatch` (safe-Rust method registry) | Production-disciplined; the audit's "unusually disciplined" verdict |
| `mdvcore-ffi` | The ONLY `extern "C"` / unsafe / symbol-export crate (cdylib + staticlib + rlib); `catch_unwind` on every entry, no-panic deny-lint wall, per-block SAFETY docs | Production-disciplined |
| `mdvcore-serve` | `mdv-serve` — the remote machine-API daemon (Unix socket, length-prefixed MessagePack envelopes, hello/version/capability handshake, duplex subscriptions, fs/git/transcript-list) | Shipped v1; remote-core carrier |
| `mdvcore-highlight` | Tree-sitter highlight runs — the one crate with unsafe C (grammar FFI), quarantined | Shipping default-ON (TSK-660) |
| `mdvcore-tui` | ratatui TUI front-end | Out of the default gate (dep scoping) |
| `mdvcore-web` | std-only HTTP front-end | Out of the default gate (dep scoping) |

### 1.2 Engines: ported, shipping, and default-ON

**Every stateless engine the migration targeted is ported, A/B-parity-validated,
and shipping default-ON** (`Sources/ViewerCore/RustCoreGates.swift`,
`defaultEnabled`). Stage A (TSK-649) is complete — every `MDV_RUST_*` capability
routes Rust by default; the Swift twins are now **fallback-only** behind
`RustCoreFallback`, pending owner-gated deletion.

| Capability | Rust module | Swift incumbent (now fallback) | Port ticket | Default |
|---|---|---|---|---|
| `csv` | `core/src/csv.rs` + `session.rs` + `filter.rs` | `CSVParser`/`CSVFilter`/`CSVFind` | beachhead (`3e60cd3`) | ON |
| `cmEdit` | `core/src/cm_edit.rs` | `CMEditApplier` | slice 2 | ON |
| `diff` | `core/src/diff.rs` | `DiffParser`/`DiffHunkParser` | slice 3 | ON |
| `hex` | `core/src/hex.rs` | `HexDumpBuilder`/`HexLayout` | slice 4 | ON |
| `hexSearch` | `core/src/hex.rs` | `HexSearchEngine` | slice 5 | ON |
| `indent` | `core/src/indent.rs` | `IndentDetector` | slice 7 | ON |
| `fuzzy` | `core/src/fuzzy.rs` | `FuzzyMatcher` | **TSK-633** | ON |
| `find` | `core/src/find_engine.rs` | `FindEngine` | **TSK-630** | ON |
| `transcript` | `core/src/transcript.rs` | `ClaudeLogParser` | **TSK-632** | ON |
| `markdown` | `core/src/markdown.rs` (+ mermaid chunk path, TSK-661) | `HTMLRenderer` | **TSK-631** | ON |
| `highlight` | `highlight/src/runs.rs` | `TreeSitterEngine` | **TSK-660** | ON |

The four tickets the prompt flagged as "approved-but-pending" — find (TSK-630),
markdown (TSK-631), transcript (TSK-632), fuzzy (TSK-633) — are **all
`validated`**, landed with the TSK-634 export ceremony, cross-language A/B
parity suites with demonstrated teeth, and capability-bit pins on both sides.

Approved deps that landed (all `default-features = false`, TSK-629 blast-radius
verified): `regex-lite =0.1.8` (find; zero transitive, linear-time PikeVM —
ReDoS structurally impossible), `pulldown-cmark =0.13.4` (markdown; transitive =
bitflags/memchr/unicase). Transcript JSON and fuzzy were **hand-rolled** (no
serde_json, no grapheme crate) per owner rulings.

### 1.3 The FFI contract — the thin waist (TSK-580)

The audit's centerpiece. The 14 ad-hoc `extern "C"` symbols are collapsed onto
one versioned envelope dispatch:

```
mdvcore_call(method:u16, req, req_len, aux, aux_len, out_buf) -> MdvStatus
```

- Method dispatch lives in **safe Rust in core** (`core/src/dispatch.rs`,
  `Method` u16 enum, `from_u16` → `None` on unknown = never UB), host-testable
  and reusable by the FFI envelope, the TUI, `mdv-serve`, and a future WASM shim.
- **All 8 stateless methods route through `mdvcore_call`** — the Swift
  `InProcessTransport.methodIds` table is the single dispatch point; the
  per-method C symbols still exist but are no longer dispatched (slices 1/2/4/5
  landed: `46013ac`, `c667a97`, `f8025a7`).
- Method ids are codegen'd: `ffi/lib.rs` `MDV_METHOD_*` consts → cbindgen emits
  `#define`s into `mdvcore.h` → Swift shares them via `CMdvCore` with a drift-pin
  test (no hand-synced table). Method id = ABI: assign once, never renumber/reuse.
- **Contract foundations already shipped:** `mdvcore_abi_version()` +
  `MDV_WIRE_VERSION` (R3/R4), `mdvcore_capabilities()` bitmap, error-model v2
  (`WireError {code,message,data}` emitted on fault + host decode/log, TSK-577 +
  TSK-669), `TooLarge` status + windowed snapshot `mdvcore_session_snapshot_window`
  (R1), supply-chain lane (cargo-deny + cargo-audit, TSK-554), handle
  poison→`HandleDead` tri-state (TSK-541).

**One slice of TSK-580 remains open** (state = `progress`): slice 3 — the **aux
bulk side-channel** for hex render (~18 MB output) so the 16 MiB frame cap
doesn't bite — plus deprecating the now-unused per-method C symbols after a soak.

### 1.4 The remote-core path (TSK-651 epic) — already real

This is the most under-stated part of the board. A working remote tier exists:

- **`CoreTransport` seam** (TSK-652, validated): one Swift client API, two
  backends — `InProcessTransport` (FFI) and `RemoteTransport` (socket). Remote is
  a carrier swap, not a rewrite. The byte-level `call(method, requestBody)` is
  the seam; the value layer stays client-side.
- **`mdv-serve`** (the daemon): hello-first wire-version hard-close, capability
  mask, the 7 stateless engine methods dispatched directly to the same `*_wire`
  fns (no FFI hop server-side), duplex subscriptions (fs.watch, transcript.follow,
  TSK-662), git/fs/transcript-list capabilities. Binds loopback/unix-socket only;
  **the ssh tunnel is the trust boundary** (owner ruling 2026-06-12, no TLS dep).
- **Wire-boundary redaction** (TSK-658): the server *forces* transcript redaction
  regardless of the request flag — nothing unredacted leaves the machine; the
  in-process FFI keeps caller choice (local trust).
- **App attach** (TSK-665, validated): the app can spawn/connect a `mdv-serve` at
  launch and install `RemoteTransport` as the process transport.
- **Protocol spec:** `docs/REMOTE_PROTOCOL.md` v1.

### 1.5 What is still Swift (and mostly should stay)

The sans-IO discipline draws the line. These stay Swift because they are
**IO-edge, OS-integration, or view-glue** — not pure domain logic:

- **View/observation layer:** `DocumentModel` (~4071 lines, ~40% `@MainActor`
  view-glue), all the child `ObservableObject`s, SwiftUI views, the WebView
  pipeline, AppKit surfaces.
- **OS / IO edge:** file IO, `EditorWriter`, `SessionStore`, plugin process
  management, PTY/terminal, LSP host wiring, TCC-sensitive paths, security
  barriers that must stay host-side (`HTMLSanitizer` — markdown's structural HTML
  never contains raw markup; the sanitizer barrier is deliberately Swift-side).
- **Pure-domain still in Swift, intentionally NOT ported** (round-trip cost
  exceeds benefit, or owner-deferred): `HexCaretMap`/`HexLayout` caret arithmetic,
  `HexSearchEngine.offsets(ofByte:)`, `FileIconClassifier` (low value, ViewerKit
  type RustCore can't import), `Formatter`, the JSON/XML pretty-printer (spike-
  first, dep-gated), `MarkdownOutline`, `FileTreeFilter`.
- **The DocumentModel→projection observation restructure** (Phase B/C in the old
  plan): the pure tab select/close/move index math could become a `TabsReducer`
  value type, and ultimately `DocumentModel` could become a CoreClient
  projection. This is **#202 / dead-toggle territory** — supervised/eyes-on only,
  never headless, never while the screen is locked. Currently un-started and not
  on a near-term slice.

---

## 2. Phased roadmap — what ports/lands next and why

The cheap, high-value engine ports are **done**. The remaining horizon is
*finishing the contract*, *paying down the audit's Phase 0/1 debts that aren't
yet closed*, *the stateful tier*, and *hardening*. Slices are ordered by
unblock-leverage, not size.

### Phase F1 — finish the contract (highest leverage, mostly in-flight)

These unblock velocity for everything after and close audit debts.

1. **TSK-580 slice 3 — aux bulk side-channel** (`progress`). Route hex render's
   ~18 MB output (and zero-copy borrowed inputs) through the `aux` channel so the
   16 MiB frame cap stops being a wall, then put hex on the envelope. *Why now:*
   it's the last genuinely-new envelope mechanism and the only stateless path not
   yet fully on the waist.
2. **TSK-580 tail — deprecate the migrated per-method C symbols** after a soak.
   *Why:* shrinks the ABI surface to the audit's ~7-symbol thin waist; every
   symbol kept is migration debt.
3. **TSK-634 codegen consolidation** (validated) is done — keep new exports on the
   ceremony, never the old hand-rolled pattern.

### Phase F2 — Swift-twin deletion (owner-gated, Stage B)

Stage A (default-ON) is complete (TSK-649, `fixed`). **Stage B = delete the Swift
twins** once each capability has soaked ON. This is the big LoC reduction and the
moment the app truly becomes a Rust-core projection for stateless work.

- *Why gated:* deleting a fallback path removes the safety net; the owner decides
  the soak duration / when to pull each twin. Mechanically: per-capability, drop
  the Swift incumbent + the `RustCoreFallback` Swift arm, keep the gate as a
  hard-Rust assert (or remove the gate too).
- *Sequence:* longest-soaked first (csv/indent/diff → hex family → wave-1 engines
  → cmEdit, the keystroke hot path, last).
- **Owner input needed:** confirm soak is sufficient and authorize deletion (see
  §6). This is a decision, not a dep.

### Phase F3 — the stateful tier (CSV session → DocId registry)

The stateless seam is 100% on the envelope; the **handle-based** CSV session APIs
(`mdvcore_session_*`) are still pointer-shaped and outside the envelope.

- **TSK-583 — `CoreRuntime` registry + `DocId(u64, never reused)`** (`reported`).
  Replace raw `Box::into_raw` session pointers with one runtime owning
  `RwLock<HashMap<DocId, Arc<Mutex<DocumentSession>>>>`. Makes the entire
  UAF/double-free class (audit R6) *unrepresentable*: stale id →
  recoverable `DocNotFound`, never UB; Rust can dead-flag a panicked doc itself.
  *This is the precondition for putting the session APIs on the envelope and for
  the remote tier to carry stateful docs.*
- Then: thread the session methods through `mdvcore_call_rt(rt, …)` (DocId in the
  envelope) so stateful work is also a carrier-swap-able call.
- **Eviction policy is an owner product decision** (see §6): the registry ships
  enumeration/size/close-idle *hooks*, but evicting state behind an open tab is a
  UX call.

### Phase F4 — remote-core completion (TSK-651 epic)

The carrier exists; completion is breadth + the stateful tier riding it.

- Stateful session methods over the socket (depends on F3).
- LSP-over-pipe rides the same channel (TSK-659 spec written; owner-gated).
- Harden the daemon edges the audit flagged for the front-ends (R2/R7): the
  git-config-neutralization (`-c core.fsmonitor= -c core.hooksPath=`) is already
  centralized in `core::git` (TSK-549/570); confirm `mdv-serve` inherits it;
  slow-loris / inflight-slot / directory-listing caps.

### Phase F5 — hardening lanes (ongoing, dep/toolchain-gated)

Per the audit's Phase 3. Several already landed (supply-chain lane TSK-554).
Remaining, in the critique's priority order:

- **Fuzzing lane:** highlight/tree-sitter-under-ASan > web request-head/percent-
  decode > wire decode. (cargo-fuzz + libfuzzer-sys — owner-approved for Phase 3.)
- **Nightly Miri + ASan** over `mdvcore-ffi` (the tests already drive the real
  extern fns). Toolchain-gated, nightly only, never the merge gate.
- **Property tests** (wire round-trip laws, CSV parse/emit round-trip) — proptest
  or hand-rolled.
- **Shared golden corpus** replacing the hand-synced triplicated parity cases;
  then differential Rust-vs-Swift parity fuzzing.
- **Perf batch** (audit R8, behind the now-default-ON adapters): byte-span CSV
  tokenizer, `Cow` fold / zero-alloc case-fold in find, positional per-element
  wire records, per-Lang `HighlightConfiguration` cache (the last landed,
  TSK-545).

### Phase F6 — WASM tier-1 (cheap once the waist is frozen) — relates TSK-800

A tiny `mdvcore-wasm` shim exporting the **same** `(ptr,len)→(ptr,len)` envelope
over linear memory — no wasm-bindgen, no new crate deps, ~100 lines. This is what
makes the open wishlist question **TSK-800 ("Can we use WASM to reduce WebUI
duplication?")** answerable: the same sans-IO core can back the web front-end's
client side. Two must-dos the original proposal missed: (a) the trap story — wasm
has no unwinding, so a panic = torn instance; JS contract is catch-RuntimeError →
discard → re-instantiate; (b) a real execution test needs a runtime (owner ask:
wasmtime-cli or node, Phase 3). Tree-sitter/highlight stays out of tier 1
permanently. **The sans-IO constraint is precisely what keeps this nearly free —
see §5.**

---

## 3. Contract / FFI / codegen work that unblocks velocity

The thesis of the audit and this plan: **the contract is the leverage point.**
Most of it has landed; finishing it is the highest-ROI remaining work.

```
                 ┌──────────────────────────────────────────────┐
                 │           mdvcore-core (sans-IO)             │
                 │  csv diff hex find md transcript fuzzy …     │
                 │  + wire (envelope) + dispatch (Method reg.)  │  ← single source
                 └───────▲──────────────▲───────────────▲───────┘     of truth
        ┌───────────────┐│              │               │┌───────────────────┐
        │ mdvcore-ffi   ││              │               ││ mdvcore-highlight │
        │ mdvcore_call  ││ mdv-serve    │   (future)    ││ (unsafe C,        │
        │ (thin waist)  ││ (socket)     │   wasm shim   ││  quarantined)     │
        └───────▲───────┘└──────▲───────┘               │└───────────────────┘
                │ FFI           │ socket
        ┌───────┴───────────────┴───────┐
        │ Swift CoreTransport seam       │  ← in-process | remote = carrier swap
        │ (method-id table = 1 dispatch) │
        └────────────────────────────────┘
```

**Done (the velocity multiplier already in place):**
- One safe-Rust dispatch registry (`Method` enum) — adding a port = one enum arm
  + one `methodIds` row, *not* a new extern symbol + a new Swift codec.
- cbindgen-codegen'd method ids (no hand-synced table; drift-pin test).
- ABI version + capability bitmap + error-model-v2 + `TooLarge` + windowed
  snapshot — the contract foundations the audit demanded before more surface
  accreted.

**Remaining contract work:**
- Aux bulk side-channel (F1.1).
- Symbol deprecation to reach the ~7-symbol thin waist (F1.2).
- `mdvcore_call_rt` (DocId in the envelope) for the stateful tier (F3).
- Header/export snapshot test in the gate (confirm it covers `buf.rs`/`status.rs`
  repr-C types per audit R3 — `rerun-if-changed=src` directory, fail-hard on
  cbindgen failure).

---

## 4. The remote-core enabler path

The remote-core goal (engine remote, UI local; TSK-651) is **already
demonstrated end-to-end** for stateless work. The enabler chain:

1. **Sans-IO core** (done, load-bearing) — the core reads no clock, no
   randomness, does no fs/process IO (enforced by `clippy::disallowed_methods`).
   This is what lets the *same* `*_wire` fn run in-process (FFI) or server-side
   (`mdv-serve`) with no behavioral skew. **Without sans-IO, a remote tier would
   need a second implementation.**
2. **Transport-agnostic envelope** (done) — `mdvcore_call` and the socket
   envelope move *the same body bytes*; the value layer stays client-side.
3. **`CoreTransport` seam** (done, TSK-652) — one client API, carrier-swappable.
4. **`mdv-serve` + `RemoteTransport`** (done) — hello/version/capability
   handshake, duplex subscriptions, wire-boundary redaction, ssh-tunnel trust.
5. **Remaining for full remote parity:**
   - Stateful docs over the wire (gated on F3 / DocId registry).
   - LSP-over-pipe on the same channel (TSK-659, owner-gated).
   - WASM as a *third* carrier of the same envelope (F6) — the web front-end's
     client side.

**Design constraint for everything new:** the Phase 1 contract must stay
**transport-agnostic** — no method may assume in-process pointers or host
callbacks; the DocId registry is the remote enabler for state.

---

## 5. Risks + the sans-IO discipline

### 5.1 The sans-IO discipline is the load-bearing invariant

`mdvcore-core` is `#![forbid(unsafe_code)]` **and** does no IO — bytes in, values
out, no clock, no RNG, no fs/process. This is enforced, not aspirational
(`clippy::disallowed_methods`). It is the single property that makes the WASM
tier nearly free, the remote tier a carrier swap, and every engine trivially
deterministic to A/B test. **Every future port must preserve it:** anything that
needs IO (file read, git spawn, time) belongs in `mdvcore-ffi`/`mdv-serve`/a
host crate, never in core. The recently-closed TSK-570 confirmed the boundary
held when hoisting `human_size`/git-argv into core (pure helpers only; the spawn
stayed at the edge).

### 5.2 Ranked risks

1. **Stateful-tier UAF/double-free (audit R6)** — still live until TSK-583 lands;
   the raw-pointer session model is "safe only if the caller is perfect." The
   DocId registry makes the class unrepresentable. *Highest structural risk.*
2. **Swift-twin deletion removes the safety net (F2)** — once a fallback is gone,
   a Rust regression is user-visible with no auto-recovery. Mitigate: soak
   discipline, per-capability staging, keep the A/B corpus as a regression gate
   even after deletion.
3. **Premature seam over-unification** — *largely retired:* the seam is proven
   across 11 capabilities now, so generalization is data-backed, not n=1. The new
   variant is the stateful seam — do NOT bake stateless-shaped assumptions into
   `mdvcore_call_rt`; spike the session-command shape first.
4. **UTF-16/UTF-8 boundary** — handled in the shipped ports (cm_edit/find carry
   the conversion + astral/CRLF parity cases); any new port touching offsets must
   carry the same corpus.
5. **Dead-toggle in DocumentModel observation (#202)** — the projection
   restructure routes child-object updates through the parent; naive wiring kills
   live views. **Supervised/eyes-on only, never headless** — keep it off the
   autonomous loop entirely.
6. **Bundle-size cap** (48 MB total / 26 MB exec sub-cap) — the markdown +
   tree-sitter deps already landed within budget; any new dep is size-gated by
   `check-bundle-size.sh`. WASM shim adds a separate artifact, not host weight.
7. **cbindgen staleness (audit R3)** — confirm the gate's header-drift check
   covers the repr-C types in `buf.rs`/`status.rs` (not just `lib.rs`); fail-hard
   on cbindgen failure. Cheap; verify it's actually wired.
8. **Front-end edge hardening (audit R2/R7)** — git-config neutralization is
   centralized (TSK-549/570); confirm `mdv-serve` inherits it and that slow-loris
   / inflight-slot / dir-listing caps are present on the socket daemon.

---

## 6. What genuinely needs owner input

Per the standing minimal-deps + owner-gate rules. The spike is auto-approved;
these are the *decisions/approvals* that remain — deliberately short, because
most of the migration is already approved and shipped.

### 6.1 Real decisions (not deps)

| # | Decision | Why it's an owner call |
|---|---|---|
| D1 | **Stage-B Swift-twin deletion: authorize + confirm soak window** | Removing the fallback safety net per capability is a risk-tolerance call, not an engineering one. Recommend: authorize deletion of the longest-soaked (csv/indent/diff) first, hold cmEdit last. |
| D2 | **Session eviction policy** (for the F3 DocId registry) | Evicting state behind an open tab + who rehydrates on `DocNotFound` is a UX decision. The registry ships hooks (enumerate/size/close-idle); the *policy* is yours. |
| D3 | **Scope/horizon confirmation** | The spike's recommendation is **"finish the whole core, not engines-only"** — the engine ports are done, so the residual scope (contract finish + stateful tier + remote completion + hardening) *is* the whole-core path and it's incremental from here. Confirm this is the intended horizon (vs. freezing at the current default-ON state and stopping). |

### 6.2 Dependency / toolchain approvals (Phase F5/F6 only; nothing needed to proceed on F1–F4)

These are pre-vetted in the audit (§5) and only bite when the hardening/WASM
lanes start — **no new dep is required to finish the contract, delete the twins,
or land the DocId registry.**

| # | Ask | Kind | Audit recommendation |
|---|---|---|---|
| A1 | `cargo-fuzz` + `libfuzzer-sys` (+ `arbitrary`) | dev-only, isolated `fuzz/` dir | Approve for Phase F5 |
| A2 | `proptest` (or hand-rolled PRNG) | dev-dep | Either; approve one for F5 |
| A3 | Nightly toolchain (Miri, `-Zsanitizer=address`) | toolchain only | Approve — nightly lane only, never merge gate |
| A4 | `wasm32-unknown-unknown` target + a wasm runtime (wasmtime-cli or node) | toolchain + CLI | Target: approve now (free compile canary). Runtime: at F6 |
| A5 | `cargo-mutants` | CLI tool | Approve, low priority |

**Already approved + landed** (no action): `regex-lite`, `pulldown-cmark`,
cargo-deny + cargo-audit. **Explicitly rejected** (no approval sought):
flatbuffers/Cap'n Proto, comrak, criterion, uniffi/swift-bridge, serde_json,
grapheme crate.

---

## Bottom line

The "Rust migration" as originally scoped — move the pure engines out of Swift —
is **effectively done and shipping**. Eleven capabilities route Rust by default;
the thin-waist envelope is the production dispatch path; a remote `mdv-serve`
carrier already works for stateless calls. The remaining work is a **finishing
sequence**, not a rewrite:

1. **Finish the contract** (TSK-580 aux channel + symbol deprecation) — in flight.
2. **Delete the Swift twins** (Stage B, owner-authorized) — the big LoC win.
3. **Land the DocId registry** (TSK-583) — closes the last UB class and unblocks
   stateful + remote parity.
4. **Hardening + WASM** lanes — dep/toolchain-gated, audit-pre-vetted.

The one invariant that must never be traded away is the **sans-IO core**: it is
why the remote tier is a carrier swap and the WASM tier is nearly free. Owner
input is needed on exactly three decisions (twin-deletion authorization, eviction
policy, horizon confirmation) and a handful of Phase-F5/F6 dep/toolchain
approvals — none of which block the next several slices.
