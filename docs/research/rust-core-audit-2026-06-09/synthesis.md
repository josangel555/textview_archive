# rust-core: PoC → production decision document

**Audit:** 9-agent (7 primed dimensions + 2 blank-slate explorers), every finding adversarially verified, every design proposal critique-judged. **43 confirmed findings, 0 refuted, 27 judged proposals.** Detailed per-dimension reports: `/Users/me/Documents/workspaces/claude/markdown_viewer/docs/research/rust-core-audit-2026-06-09/`. Tickets: epic **TSK-538**, tag `rust-core-audit`.

---

## 1. Executive verdict

**Build on it. Do not rewrite. But do not freeze the current FFI contract — the contract layer needs a designed v1 before any more Swift surface accretes on today's patterns.**

The PoC's core discipline is genuinely production-grade already, and multiple independent reviewers converged on that without prompting:

- `#![forbid(unsafe_code)]` sans-IO core; all unsafe quarantined in one 626-line FFI crate with per-block SAFETY docs; tree-sitter's unsafe isolated in `highlight`.
- The no-panic deny-lint wall is **enforced by a real gate**, and the gate's own lint config is regression-tested (`crates/ffi/tests/no_panic_lints_gate_*.rs`).
- The panic boundary is *correct*, not cargo-culted: `catch_unwind` on every export, and `scripts/build-rust-core.sh` actively **rejects** linking the `panic=abort` profile into the GUI host, so the guard is load-bearing.
- Wire hygiene: trailing-garbage-rejecting decode, hostile-length-prefix guard, a byte-identity oracle pinning the single-alloc encoder to a retained legacy implementation.
- Deliberate cross-language A/B parity tests through the real staticlib; exact-pinned minimal deps (serde + rmp-serde only in the gate path).

**Zero S1 findings across 43 adversarially-verified findings; zero refuted; the verifiers adjusted severity *downward* on 5.** Three separate reviewers independently called it "unusually disciplined." That is the strongest possible signal that the foundation is sound.

What is *not* production-grade is the **contract and the edges** — and these are design debts, not algorithm bugs:

1. The FFI key path has a **structural functional cliff** (16 MiB frame cap vs. 256 MiB parser limits) — a ~20 MB CSV opens fine, then every pull fails forever with an opaque error. Reproduced empirically.
2. **No ABI/protocol version exists anywhere**, the cbindgen header can silently go stale (ABI-drift → memory-corruption enabler), and the documented rich-error channel is dead code.
3. One genuine **code-execution class** in the front-end tiers (`git status` without config neutralization on browsed untrusted directories).
4. ~8,300 lines (tui/web/highlight, including the only crate parsing attacker files through unsafe C) sit **outside every lint and test gate** and are measurably rotting.
5. Every adversarial-input discipline (fuzzing, property tests, Miri/ASan, mutation measurement) is absent or a dead letter (`deny.toml` committed, never run).

None of this warrants a rework-before-building. It warrants a **contract freeze done deliberately** (Phase 1 below) instead of organically, plus a short fix-first list. The thing to explicitly *not* do: keep adding per-feature `extern "C"` symbols + hand-rolled Swift codecs on the current pattern while the contract questions are open — each one added now is migration debt.

---

## 2. Top risks (confirmed, deduplicated, by real-world impact)

No S1s exist. These are the confirmed S2s plus the S3 clusters that gate the production goal.

### R1 — S2 · The 16 MiB wire ceiling structurally breaks the flagship CSV path (and snapshots are O(table) per pull)
*Found independently by 4 dimensions; reproduced with a live 21 MB CSV.*
- `MAX_FRAME_LEN = 16 MiB` (`rust-core/crates/core/src/wire.rs:73`) is documented as a **decode-side** hostile-prefix guard but is also enforced on **encode** (`wire.rs:163-167`), while `csv::Limits::default()` admits 32 M cells / 256 MiB (`csv.rs:44-49`). Net: `mdvcore_session_open` succeeds on a 50 MB CSV, then **every** `session_table`/`session_snapshot` fails forever with the generic `MdvStatus::WireError` — indistinguishable from a codec bug in Swift, no windowed/range API as a workaround (`ffi/src/lib.rs:489, :587`). Already live today: `RustCSVAdapter` silently falls back to Swift for exactly the large files Rust should win.
- Compounding: `snapshot_frame` (`session.rs:162-184`) re-serializes **all visible rows** on every pull (~9 MB of MessagePack per filter change on a 100k×10 table), duplicating rows Swift already holds.
- **Fix shape:** decouple the decode guard from encode; distinct `TooLarge` status; windowed snapshot `{offset, limit}` (indices-only or viewport rows); window or shrink `session_table` too — windowing only the snapshot leaves the same wall on the open-time pull.

### R2 — S2 · `git status` on browsed directories executes attacker config (`core.fsmonitor`) — RCE-on-browse in TUI/web
- `web/main.rs:822-826` (every `/browse`, `/view`, `/grep` render) and `tui/main.rs:2954-2960` spawn `git -C <dir> … status` without neutralizing repo-local config. A downloaded/unpacked directory carrying a hostile `.git/config` with `core.fsmonitor = <cmd>` executes attacker commands **on directory listing alone** — the known fsmonitor attack class that forced VS Code's repo-trust prompts. Confined to the non-shipping front-ends (below S1), but it's a one-line fix: `git -c core.fsmonitor= -c core.hooksPath= …`.

### R3 — S2 · cbindgen header silently goes stale → cross-language ABI drift with no detection (memory-corruption enabler)
- `ffi/build.rs:32-34` emits `rerun-if-changed` for only `src/lib.rs`/`cbindgen.toml`/`build.rs`, but the `#[repr(C)]` ABI types live in `buf.rs:13-22` (`MdvBuf`) and `status.rs:14-35` (`MdvStatus`) — edit those, the staticlib rebuilds, the header doesn't regenerate, and `scripts/build-rust-core.sh` stages the stale mirror for the Swift compile. build.rs also tolerates cbindgen *failure* with a warning (`build.rs:61-64`). Silent field-offset skew = cross-language memory corruption with zero compile- or gate-time signal. **Fix:** `rerun-if-changed=src` (directory), fail-hard on header-gen failure, gate-time header-drift check — and `mdvcore_abi_version()` (R4) as the runtime backstop.

### R4 — S2-class design gap · No ABI or wire-protocol version anywhere; the promised rich-error channel is dead code
- No version export among the 14 `extern "C"` fns, no version in any frame, workspace version permanently `0.0.0`. The VM links a prebuilt `libmdvcore_ffi.a` against rsync'd Swift sources — a real skew vector with no detection.
- `WireError {code, message, data}` (`wire.rs:62-69`) is constructed **only in its own unit test**; every FFI error arm discards the fault detail (`lib.rs:146, 192, 237, 351, 495, 587`), and `session_open` collapses all errors to `BadUtf8` (`lib.rs:459`). The docs (`lib.rs:10-11`, `status.rs:7-8`) promise a contract the code never implements. Swift can never see *why* anything failed — including R1's "too large".

### R5 — S3 (confirmed) · ~8,300 LoC outside every gate; security/UB tooling are dead letters
- `rust-core-gate.sh:34,37` run without `--workspace` → `default-members = [core, ffi]` only. `highlight` (the unsafe grammar-FFI crate parsing attacker files), `tui` (60 tests), `web` (75 tests) are **never compiled, linted, or tested in any lane** — 144 passing tests gate nothing; rot is measurable (compiler-proven dead code, the gate header's own comment is false). `deny.toml` is committed but cargo-deny/cargo-audit/Miri never run, while `ffi/tests.rs:208` explicitly defers leak/double-free detection to "Miri / ASan". Cheap to close, disproportionate risk to leave.

### R6 — S3 cluster · Handle/buffer lifetime safety is convention-only on the key path
- Free-vs-in-flight-call is undetected UB (`handle.rs:87-93` unconditionally drops; the `try_lock→Busy` model guards data, not lifetime) — exactly the misuse Swift ARC/deinit timing is most likely to commit.
- Poisoned-lock recovery serves post-panic, possibly half-mutated state (`handle.rs:104-109`), contradicting the documented drop-&-recreate contract; only the in-tree Swift wrapper enforces it.
- `MdvBuf` is a copyable POD whose `cap` is load-bearing for free → struct-copy + double-free = UB by construction (`buf.rs:52-64`); plus the documented "data null when len==0" is false (dangling non-null).
- All currently mitigated by the disciplined Swift wrapper — but "safe only if the caller is perfect" is below the stated bar. The registry/handle-table model (Section 3) makes the whole class unrepresentable.

### R7 — S3 cluster · Hostile-input resource exhaustion at the edges
- CSV cell-count cap is decoupled from memory: ~4 MB of bare newlines → ~480 MB resident (empirically ~120× amplification; ~3.8 GB at the cap) through `mdvcore_session_open` (`csv.rs:44-49`).
- `mdvcore_hex_render` width is unvalidated — `width=u32::MAX` requests ~17 GiB; alloc failure **aborts past the panic guard** (`ffi/lib.rs:283`, `hex.rs:72`).
- `hunk_marks` does unguarded i64 arithmetic on attacker diff headers — reproduced panic in dev, silent wrap in release (`diff.rs:474-517`); the structured parser clamps (`MAX_COORD`), this twin doesn't. Related parity-locked bug: top-of-file deletions land the gutter mark on line 0 (invisible) — **shared with the shipping Swift parser**, so A/B tests can never catch it.
- Web tier: slow-loris drip survives ~64 h per connection (per-read timeout only); worker panic leaks an inflight slot permanently (128 leaks = permanent 503, and `[profile.release] panic=abort` kills the whole server); directory listing is unbounded; served-root **fails open to `/`** on canonicalize error and persists the broken root to config (`web/main.rs:159`).

### R8 — S3 cluster · Efficiency debt contradicting the "hyper-efficient" mandate
Confirmed but mostly not yet on live paths (adapters default-OFF): `cm_apply` ships the full document both directions per edit batch (~10× doc size per debounce tick); `Vec<Vec<String>>` table storage (~2 allocations/cell-row, cache-hostile filter scans); char-at-a-time CSV tokenizer (~5-10× below span scanning); per-line `String` allocation in `find_matches` (with a false "no allocation" doc comment); named-map MessagePack pays ~41 B/line of repeated key text in hot per-element collections; tree-sitter query recompiled per call (per HTTP request in web); two no-panic lint holes (`clippy::string_slice`, arithmetic overflow) that the gate cannot see.

---

## 3. The target architecture

Synthesized from the sound-with-caveats proposals, with conflicts adjudicated. One proposal was rejected outright: **"One highlighter for all front-ends" (verdict: weak, effort epic)** — its motivating bug (TSK-410) is already fixed in Swift, and as specced it would *increase* engine count. If unification is ever wanted, do **query-level** (.scm) sharing, not engine-level.

```
                 ┌──────────────────────────────────────────────┐
                 │           mdvcore-core (sans-IO)             │
                 │  csv diff hex find … + wire (envelope v1)    │
                 │  + dispatch (method registry, safe Rust)     │
                 └───────────▲───────────────────▲──────────────┘
        ┌───────────────┐    │                   │   ┌───────────────────┐
        │ mdvcore-app   │────┘                   └───│ mdvcore-highlight │
        │ (Elm Model/   │  pure                      │ (unsafe C,        │
        │ Msg/update)   │                            │  quarantined)     │
        └──▲─────────▲──┘                            └───────────────────┘
           │         │ effects (data only)
   ┌───────┴────┐ ┌──┴─────────┐      mdvcore-host: read_capped, config
   │ tui        │ │ web        │ ◄──  codec, git spawn (config-neutralized),
   │ (render)   │ │ (stateless)│      ONE confined dir/grep walker
   └────────────┘ └────────────┘      (the ONE std-IO crate)

   FFI thin waist (frozen, ~7 symbols, evolvable forever via the envelope):
     mdvcore_abi_version() -> u32                     ← startup skew check
     mdvcore_call(req, len, aux, aux_len, out)        ← stateless envelope
     mdvcore_runtime_new/free                         ← ONE handle per app
     mdvcore_call_rt(rt, req, len, aux, aux_len, out) ← doc_id IN the envelope
     mdvcore_buf_free  ·  mdvcore_last_error(out)
   WASM tier-1 = the same envelope over linear memory (no new deps).
```

### FFI contract (the thin waist)
Collapse the 14 ad-hoc symbols (three of which are byte-identical copy-paste) to one versioned envelope-dispatch entry plus lifecycle fns. Method dispatch lives in **safe Rust in core** (host-testable without FFI, reusable by TUI/web/WASM). Decisions where proposals conflicted:

- **Aux-bytes side channel, not envelope-everything.** The critiques killed naive "everything rides the frame": hex render's ~18 MB output and zero-copy borrowed inputs (`hex_render`/`hex_search`) collide with the frame cap and would force multi-MB request copies. `mdvcore_call(req, req_len, aux, aux_len, out)` keeps one frozen entry while big payloads ride out-of-band. Document the framed-vs-raw split as explicit policy (framed = structured, raw = opaque bulk).
- **u16 method ids, codegen'd into both sides** (build.rs emits a Swift constants file alongside the header) — kills the string-typo class structurally.
- **Version: startup check, not per-frame.** `mdvcore_abi_version()` + a cbindgen-emitted `MDV_WIRE_VERSION` constant asserted by Swift at bridge init (catches the VM prebuilt-`.a` skew). Per-frame `v` is deferred until an independently-versioned transport (socket/WASM peer) actually exists — a process-static staticlib can't skew mid-process.
- **Hygiene in the same freeze:** rename the unprefixed `SessionHandle` typedef (`MdvSession`), feature-gate `mdvcore_add`/`mdvcore_force_panic` out of production builds, exported-symbol allowlist.

### State model: runtime registry, not raw pointers
One `CoreRuntime` handle owning `RwLock<HashMap<DocId, Arc<Mutex<DocumentSession>>>>`; **DocId = monotonic u64, never reused** (kills ABA without generation counters). Stale/closed id → recoverable `DocNotFound`, never UB — the entire UAF/double-free class from R6 becomes unrepresentable, and Rust can dead-flag a panicked doc itself (`DocPoisoned`) instead of trusting each host wrapper. Per-doc `try_lock→Busy` semantics survive (clone the Arc, drop the map lock, then try_lock). Eviction ships as **hooks** (enumeration + size estimation + close-idle), not policy — evicting open-tab state is an owner product decision. Until the registry lands, the minimal hardening is the Mutex-poison tri-state in `with()` (`Ok/Busy/Poisoned→HandleDead`) — automatic, exact, no new state.

### Error model
- `MdvStatus` shrinks to **transport faults** (NullArg, Panic, Busy, TooLarge, HandleDead/DocNotFound, encode-failure).
- On any non-Ok from an out-buf method, the out-buf carries the **encoded `WireError {code, message, data}`** the docs already promise. Code space: 1–99 transport (mirrors the status enum), 100+ domain (e.g. `OpenError::BadUtf8` with `valid_up_to`).
- For fns without an out-buf (`session_open`, `set_filter`): **thread-local last-error + `mdvcore_last_error(out_buf)`** (the libgit2/SQLite pattern) — covers every entry point uniformly, no ABI churn, and avoids making raw-UTF-8 endpoints' buffers bimodal. This supersedes the per-fn `out_err` param variant.
- Land first, independently: exhaustive `match` on `OpenError` (5 lines) so a new variant is a compile error, not a silent `BadUtf8`.

### Wire / RPC
- **MessagePack named maps stay** for envelope-level structures (owner mandate: binary; field-name maps = free additive evolution; Swift decoder exists). Flatbuffers/Cap'n Proto **rejected**: new deps, and Swift copies into native String/Array anyway — the zero-copy win is illusory on this host.
- **Per-element hot records go positional** (serde tuple structs): diff `Line` → `[kind:u8, old, new, content]` — ~4-6× size cut where key bytes dominate. The Swift decoder is hand-rolled, not Codable; positional is fully in reach.
- **Windowed snapshots**: `snapshot{offset, limit}` returning `{header, window, total_rows, matched_rows, version, query}` — level-triggered semantics preserved as "full truth *for the viewport*", cost drops O(matches)→O(viewport), and the 16 MiB cap stops being a wall. Pin stale-offset semantics (clamp, never error). **`session_table` must be windowed or shrunk to header+metadata too** — otherwise the wall survives on the open-time pull.
- **De-frame the FFI tier**: `MdvBuf.len` is the frame; the u32 prefix is dead weight in-process (it currently costs Swift two full copies per response). Framing stays in `wire.rs` as a transport-adapter concern for the future socket/stream tiers.
- 16 MiB guard: keep on **decode** (hostile prefixes); encode gets a distinct `TooLarge` plus per-payload-class budgets.

### Crate structure
- **Phase it: `mdvcore-host` first** (read_capped, mtime_secs, human_size, ONE shared hand-rolled config codec — *not* serde'd, that's deliberate hand-editability — git spawn with config neutralization baked in, one bounded dir/grep walker taking an un-forgettable `ConfinedRoot` newtype so the web tier's traversal defense can't be dropped in the unification). This captures most of the verified duplication at a fraction of the risk.
- **`mdvcore-app` (Elm-style Model/Msg/update→Effect) is TUI-scoped**; the web tier is deliberately stateless and should adopt pure orchestration pieces à la carte. The "one feature lands once for all front-ends" payoff was judged overstated — budget accordingly. Specify the effect-runner contract (every Effect has exactly one completion Msg, failures are data) before building.
- `mdvcore-app` joins `default-members` so the parity layer is permanently gated; shared caps/constants (GREP_*, PREVIEW_CAP, HEX_WIDTH) move into core so the hand-synced mirrors can't drift.

### WASM path
Tier 1 is **core-only and nearly free once the envelope exists**: a tiny `mdvcore-wasm` shim exporting the same `(ptr,len)→(ptr,len)` envelope over linear memory — no wasm-bindgen, no new crate deps, ~100 lines of glue. Two must-dos the proposal missed: (a) **the trap story** — wasm has no unwinding, so a panic = torn instance; the JS contract must be catch-RuntimeError → discard → re-instantiate; (b) **a real execution test needs a runtime** (owner ask below) — `cargo check --target wasm32-unknown-unknown` proves compilation only (and is *not* a sans-IO guard; that enforcement belongs in `clippy.toml` `disallowed-methods`, which already exists and should be extended). Tree-sitter/highlight stays out of tier 1 permanently.

---

## 4. Roadmap

### Phase 0 — fix before anything (confirmed criticals + cheap structural closures) · ~1-2 weeks
| Item | Effort |
|---|---|
| `git -c core.fsmonitor= -c core.hooksPath=` in both front-end spawns (R2) + per-dir cache in web | XS |
| Web root fail-**closed** on canonicalize error; validate CLI start-dir; don't persist a broken root (R7) | XS |
| cbindgen: `rerun-if-changed=src`, fail-hard on generation failure, gate-time header-drift check (R3) | S |
| Distinct `TooLarge` status + drop the encode-side reuse of the decode guard (stopgap for R1) | S |
| `OpenError` exhaustive match (kills silent mis-report) | XS |
| `hunk_marks`: clamp/saturate i64 cursors + `max(1)` top-of-file deletion fix **landed simultaneously in Swift** (parity-locked) | S |
| Clamp `hex_render` width at the FFI edge; make `rendered_row_length` total | XS |
| Web: RAII inflight-slot guard + explicit bin panic policy; request wall-clock deadline; directory-listing cap | S |
| CSV: add `max_rows` / byte-accounted cap so memory is O(input) (R7) | S |
| Deny `clippy::string_slice` (+ decide `arithmetic_side_effects` for core); fix the ~10 sites | S |
| Gate: workspace-wide clippy+test stage (lint profiles for tui/web/**highlight**); fix the false gate comment | S |
| `.cargo/config.toml` `build.target-dir` out of the iCloud tree (delete the 2.7 GB `target/`); `rust-version = "1.88"` | XS |
| Hygiene sweep: dead `render_view`, unused ffi serde deps, the 60-warning saturation, success-path `cargo:warning` | S |

### Phase 1 — the contract freeze (foundations everything else rides on) · ~3-5 weeks
- `mdvcore_abi_version()` + `MDV_WIRE_VERSION` + Swift startup assert; header/export snapshot test in the gate. **(S)**
- Error model v2: status taxonomy, WireError frames in out-buf, TLS `mdvcore_last_error`, poison→`HandleDead` tri-state; restructure Swift `callBuf`/`check` to decode the error frame pre-throw; update the now-contradicted doc lines. **(M)**
- Windowed snapshot `{offset,limit}` + window/shrink `session_table`; reconcile `csv::Limits` with the transport bound. **(M)** *(This is the real R1 fix.)*
- Thin-waist envelope `mdvcore_call` with aux-bytes channel + u16 method-id codegen into both sides; migrate the three copy-paste stateless fns first; old symbols coexist during migration. **(L)**
- De-frame the FFI tier (MdvBuf.len is the frame); typed enums/validated scalars (`BadArg` on unknown mode/scope); symbol hygiene (rename, feature-gate test hooks). **(S-M)**
- Complete the FFI misuse-test matrix (the one **strong**-verdict proposal: 6 untested exports, deterministic Busy test, poison-path test — the current contention test is a confirmed test-lie that cannot fail). **(S)**

### Phase 2 — structure · ~4-6 weeks
- `CoreRuntime` registry + DocId model; retire raw session pointers (Swift keeps a thin shim during migration). **(M-L)**
- `mdvcore-host` extraction with `ConfinedRoot`; then `mdvcore-app` for the TUI; web adopts pure pieces. **(M, then L)**
- Stateful Rust-side editor doc (rope/piece-table, UTF-16-unit addressed) so `cm_apply` carries only `{from,to,insert}` + occasional resync. **(M)**
- Compact table store (contiguous cell arena + u32 offsets) behind the session; `Table` stays the wire DTO. **(M)**
- Perf batch: byte-span CSV tokenizer (existing tests as parity oracle), `Cow` fold / zero-alloc case-fold scan in find, per-Lang `HighlightConfiguration` cache, positional per-element wire records, TUI per-frame caches. **(M total)**

### Phase 3 — hardening · ongoing lanes
- Fuzzing lane (priority order per critique: **highlight/tree-sitter under ASan** > web request-head/percent-decode > wire decode); oracles beyond no-panic (reference splice, valid-UTF-16). **(M, dep-gated)**
- Property tests: wire round-trip laws, CSV parse/emit round-trip (pre-normalized tables), session op-replay. **(M, dep-gated or hand-rolled)**
- Nightly Miri + ASan lane over `mdvcore-ffi` (the tests already drive the real extern fns); cargo-deny + cargo-audit in the same lane. **(S, toolchain-gated)**
- Shared golden corpus replacing the hand-synced triplicated parity cases (use the `#filePath` walk-up pattern, not SwiftPM resources); then differential Rust-vs-Swift parity fuzzing (fixed seeds in the merge gate, varying seeds nightly). **(M)**
- Periodic cargo-mutants audit + hand-rolled perf-floor bench (ratchet vs. previous run, not absolute thresholds; GH-hosted runner — the VM has no Rust). **(S-M)**
- WASM tier-1 shim + execution test once the envelope is frozen. **(M)**

---

## 5. Dependency / toolchain decisions needed from the owner

Per the standing rule, nothing below is assumed. Each is a crisp yes/no.

| # | Ask | Kind | Why / scope | Recommendation |
|---|---|---|---|---|
| 1 | **memchr** | crate dep (core) | SIMD memmem for CSV span scanning, hex search, find. Ubiquitous (~0 transitive deps, BurntSushi). Hand-rolled byte loops get most of the win first. | Defer — hand-roll in Phase 2, approve only if benches show the gap matters |
| 2 | **cargo-fuzz + libfuzzer-sys** (+ `arbitrary`) | dev-only, isolated `fuzz/` dir (not in workspace members) | Phase 3 fuzz lane; the only credible way to exercise tree-sitter's C under ASan with hostile files | **Approve** for Phase 3 |
| 3 | **proptest** | dev-dep | Property/round-trip laws. Alternative: hand-rolled PRNG generators (zero-dep, more code) | Either; approve one |
| 4 | **cargo-deny + cargo-audit** | CLI tools (not crate deps) | `deny.toml` is already committed and admits it's a dead letter; 13 exact-pinned tree-sitter crates get zero advisory scanning | **Approve** — install + nightly lane |
| 5 | **Nightly toolchain (Miri, `-Zsanitizer=address`)** | toolchain only | UB/leak verification of the one unsafe crate; the FFI tests were explicitly written anticipating it | **Approve** — nightly lane only, never the merge gate |
| 6 | **cargo-mutants** | CLI tool | Periodic teeth-measurement audit (the project's own TEETH rule, mechanized) | Approve, low priority |
| 7 | **wasm32-unknown-unknown target** + a wasm test runtime (**wasmtime-cli** or node, dev/CI tool) | toolchain component + CLI | Tier-1 WASM compile canary now; an actual execution test when the shim ships (compile-check alone can't satisfy the tests mandate) | Target: approve now (free). Runtime: approve at Phase 3 |
| 8 | **Explicitly rejected — no approval sought:** flatbuffers/Cap'n Proto (zero-copy is illusory on this host), criterion (hand-rolled ratchet bench instead), uniffi/swift-bridge (unnecessary once the waist is ~7 symbols), toml/serde for front-end config (the hand-rolled codec is a deliberate, documented choice) | — | — | — |

**One product decision parked for you (not a dep):** session **eviction policy** in the multi-document runtime — the registry ships enumeration/size/close-idle hooks, but evicting state behind an open tab (and who rehydrates on `DocNotFound`) is a UX call, not an engineering one.

---

### Bottom line

The PoC earned the right to become the real thing: the safety architecture, the gate discipline, and the parity methodology are exactly what a production core needs, and 43/43 adversarially-verified findings produced zero rewrite-grade defects. The commitment to make is **Phase 0 + the Phase-1 contract freeze before any new FFI surface is added** — the 16 MiB cliff, the versionless ABI, the dead error channel, and the raw-pointer handle model are all cheap to fix now and expensive to fix after ten more methods and three more front-ends are riding on them.