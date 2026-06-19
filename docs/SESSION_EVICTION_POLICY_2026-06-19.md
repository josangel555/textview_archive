# Session eviction policy for the multi-document runtime — design / decision spike

**Ticket:** TSK-589 — `[RUST-CORE][OWNER-DECISION]` Session eviction policy for the multi-document runtime.
**Date:** 2026-06-19
**Status:** RESEARCH + DESIGN. No code change. One value/policy choice is parked for the owner (§6); everything else is buildable as designed.

---

## 1. Current behavior (verified, not assumed)

There are **two** "multi-document" surfaces in `rust-core/`. Only one is stateful. Neither evicts.

### 1a. The FFI session registry — the real (today) multi-document runtime

`rust-core/crates/ffi/src/handle.rs` is the live store of in-memory documents:

```
static REGISTRY: OnceLock<Mutex<HashMap<usize, Arc<SessionHandle>>>>
SessionHandle { inner: Mutex<CsvSession> }      // one open document
NEXT_TOKEN: AtomicUsize  (1-based, monotonic, never reused → no ABA)
```

Lifecycle:

| Op | Code | Effect on registry |
|----|------|--------------------|
| Open | `mdvcore_session_open` → `CsvSession::open` → `SessionHandle::into_raw` (`lib.rs:635`, `handle.rs:92`) | **inserts** one entry; token handed to Swift as an opaque `*mut SessionHandle` |
| Call | `mdvcore_session_*` → `SessionHandle::lookup` (`handle.rs:110`) | clones the `Arc` out under the lock; **no insert/remove** |
| Free | `mdvcore_session_free` → `SessionHandle::free` (`handle.rs:126`) | **removes** the entry (idempotent; defers drop to the `Arc` if a call races) |

**The only removal path is an explicit `free`.** There is no cap, no LRU, no TTL, no size accounting, no enumeration. The registry grows by one entry per open and shrinks only when Swift frees. The `usize`-keyed `HashMap` is, today, an unbounded set of retained documents.

What an entry costs: a `CsvSession` (`crates/core/src/session.rs`) owns a `TableArena` — **one contiguous text buffer + a flat offset table** for the whole CSV — plus a `Query` and an indices-only filter cache (`CachedView` is asserted to be `{u64, Vec<u32>}`, no second row copy; `session.rs:393`). So per-document RAM ≈ the file's text bytes + ~4 B/row of offsets + ~4 B/surviving-row of filter cache. A handful of 50 MB CSVs = hundreds of MB resident, held until `free`.

### 1b. What actually bounds it today: Swift ARC, not the core

`Sources/RustCore/CoreClient.swift:256` wraps each handle in a Swift `final class CsvSession` whose `deinit` calls `mdvcore_session_free` **exactly once** (`CoreClient.swift:280`). So a document is evicted from the Rust registry precisely when the Swift wrapper is deallocated by ARC — i.e. when the last Swift reference (a closed tab / dismissed view model) drops. **The eviction "policy" today is implicit and lives entirely on the Swift side: whatever the app's retain graph decides.** The Rust core is a passive bag with no opinion and no visibility.

Consequence: if the Swift app ever holds CSV sessions longer than the visible tab (a recent-files cache, a background pre-parse, a leaked closure capture, or a future where the *core* is asked to keep more docs than the UI shows), nothing in the core pushes back — RSS climbs until ARC happens to release, or never.

### 1c. The stateless surfaces (not in scope, for contrast)

- **`mdv-serve`** (`crates/serve/src/serve.rs`) is request/response engine dispatch — `cm_apply`, `find_search`, `markdown_render`, etc. It holds **no per-document session state** (the per-connection `WatchHub` is fs-watch subscriptions, torn down on disconnect). So the remote core has *no* document registry today.
- **TUI / web** front-ends own their own single-document state outside this registry.

### 1d. Where this is headed (the audit's planned state model)

`docs/research/rust-core-audit-2026-06-09/synthesis.md:111` defines the Phase-2 target the eviction policy must fit:

> One `CoreRuntime` handle owning `RwLock<HashMap<DocId, Arc<Mutex<DocumentSession>>>>`; **DocId = monotonic u64, never reused**. Stale/closed id → recoverable `DocNotFound`, never UB. … **Eviction ships as hooks (enumeration + size estimation + close-idle), not policy — evicting open-tab state is an owner product decision.**

And `synthesis.md:196` explicitly parks *this ticket*:

> **One product decision parked for you:** session **eviction policy** in the multi-document runtime — the registry ships enumeration/size/close-idle hooks, but evicting state behind an open tab (and who rehydrates on `DocNotFound`) is a UX call.

`DocId` is referenced in code only as a future ("Phase-2 DocId registry", `Sources/RustCore/CoreTransport.swift:11`). It does not exist yet. The `usize` token in `handle.rs` is its de-facto precursor and would become the `DocId`.

---

## 2. The problem, framed precisely

| Question | Answer |
|----------|--------|
| **What grows unbounded?** | The `HashMap<token, Arc<SessionHandle>>` in `handle.rs` — one retained `CsvSession` (≈ file-size text buffer) per open, removed only by explicit `free`. |
| **What triggers retention?** | An `open` with no matching `free`. Today `free` is ARC-`deinit`-driven on the Swift side, so retention = "the Swift wrapper is still alive". |
| **What's the memory risk?** | Resident RAM = Σ(open document text + offsets + filter cache). Several large CSVs, or a host that retains sessions past their visible tab, drives RSS up with no core-side ceiling and no back-pressure signal. |
| **What's the UX risk on the *fix* side?** | Any policy that frees a document the user can still see ("surprise close") is worse than the leak. A `DocNotFound` on a live tab must be *recoverable* (re-open from the original bytes), and the active/visible doc must never be a victim. |
| **What's the remote-core risk?** | When the registry moves behind `mdv-serve`, the host (Swift) and the store (Rust, possibly out-of-process) no longer share an address space *or* an ARC graph. ARC-driven `deinit`-free **stops working as the implicit GC**: a crashed/disconnected client orphans its documents server-side forever. The eviction policy is what *replaces* ARC as the lifetime authority across the wire. This is the real forcing function — it is not optional once the core is remoted. |

So the policy must satisfy four constraints simultaneously: **(a)** put a hard ceiling on resident document RAM, **(b)** never evict the active/visible doc, **(c)** make eviction *recoverable* (host can rehydrate on `DocNotFound`), **(d)** survive the transition to a remote/out-of-process core where ARC is no longer the GC.

---

## 3. Options

Mechanism vocabulary used below:
- **Pinning** — the host marks the active/visible DocIds; pinned docs are exempt from eviction.
- **Idle clock** — `last_touched` timestamp bumped on every call to a doc; basis for LRU and TTL.
- **Size estimate** — `DocumentSession::estimated_bytes()` (text buffer + offsets + cache); basis for a byte budget.
- **`DocNotFound` rehydration** — the host keeps the original file bytes (or a path) and re-`open`s on a `DocNotFound`, transparently to the user.

| # | Policy | Memory bound | Surprise-close UX | Impl complexity | Remote-core fit | Notes |
|---|--------|--------------|-------------------|-----------------|-----------------|-------|
| 0 | **No eviction (explicit close only)** — today's behavior, formalized | **None** — unbounded | None (nothing is auto-closed) | Trivial (already done) | **Poor** — orphans on client crash/disconnect leak forever server-side | The status quo. Fine while ARC is the GC in-process; fails the moment the core is remoted or the host over-retains. |
| 1 | **LRU by count** — cap at N open docs, evict least-recently-used over N | Weak — N × *largest* file; one 500 MB CSV blows the budget at N=1 | Medium — a doc can vanish purely because N others were opened, regardless of its size | Low — idle clock + a count check on insert | OK | Count is a poor proxy for RAM; a "small N" that's safe for big files is annoyingly tight for small ones. |
| 2 | **LRU by total bytes** — cap at B total resident bytes, evict LRU until under B | **Strong** — hard RAM ceiling | Medium — large docs evict sooner; eviction order is size-blind (pure recency) | Medium — idle clock + size estimate + evict loop | Good | The right *bound*, but pure recency can evict a doc the user just scrolled away from while keeping a stale-but-recently-touched one. |
| 3 | **TTL (close-idle)** — evict any doc untouched for T | Weak — a burst of opens within T all stay resident | Low-Medium — predictable ("untouched for 10 min ⇒ dropped"); but a doc the user *is* viewing but not interacting with can age out | Low — idle clock + a sweep | Good — naturally reaps orphans from a dead client | Time-based, not memory-based; doesn't cap a burst. Best as a *secondary* reaper, not the primary bound. |
| 4 | **Hybrid: byte budget + count cap, with pinning of active/visible docs, plus a TTL idle-reaper** | **Strong** — byte ceiling is the hard bound; count cap is a cheap secondary guard | **Lowest** — pinned (active/visible) docs are never victims; only background/recent docs evict; host rehydrates on `DocNotFound` | Medium-High — pinning API + idle clock + size estimate + dual budget + reaper | **Best** — pinning + `DocNotFound` rehydration is exactly the contract a remote client needs; TTL reaps orphaned-by-disconnect docs | The union that satisfies all four §2 constraints. Each piece is independently testable. |

---

## 4. Recommendation — Option 4 (hybrid, pinned, recoverable)

**Adopt Option 4: a byte-budget + count-cap LRU eviction with host-driven pinning of active/visible documents, a TTL idle-reaper as the orphan backstop, and recoverable `DocNotFound` rehydration.** Ship the *mechanism* now; expose the *thresholds* as config (the owner sets defaults — §6).

### Why this one (production-grade, future-proof)

- **It is the only option that meets all four constraints in §2.** Byte budget = hard RAM ceiling (constraint a). Pinning = the active/visible doc is structurally un-evictable (constraint b). `DocNotFound` + host-kept bytes = recoverable (constraint c). TTL reaper = orphan cleanup that doesn't depend on ARC, so it survives remoting (constraint d). Options 0–3 each fail at least one.
- **Byte-bound, not count-bound, is the correct ceiling** because document cost spans four orders of magnitude (a 2 KB config vs a 500 MB log). A count cap either over-commits RAM (N small → fine; N large → OOM) or starves the small-file case. The count cap survives only as a cheap secondary guard against pathological many-tiny-docs map bloat.
- **Pinning makes "surprise close" structurally impossible for the active doc**, which is the dominant UX failure mode of naive LRU. The host already knows which DocIds are visible (it owns the tab strip); a one-call-per-focus-change `set_pinned` is cheap.
- **It is the natural home for the audit's planned hooks.** `synthesis.md` already commits the registry to ship *enumeration + size estimation + close-idle* hooks. Option 4 is precisely "wire a policy onto those hooks" — no new architecture, and the hooks stay independently useful (diagnostics, a memory HUD, manual close-others).
- **It is transport-agnostic.** Pinning is host→core signal; eviction + `DocNotFound` is core→host signal. Both ride the existing envelope. Nothing about the policy assumes a shared address space, so it lands identically for in-process FFI and remote `mdv-serve` — which is the whole point of the rust split (remote-core goal).

### What we deliberately do NOT do

- **No automatic persistence-on-evict.** Eviction drops *in-memory* parse/filter state only. The source of truth (file bytes / path) lives host-side; the host re-opens on `DocNotFound`. Persisting evicted state to disk in the core would duplicate the app's Sessions store and put file I/O in the engine — wrong layer. (If a doc has *unsaved edits* that exist only in core state, that doc must be **pinned by the host** and is therefore never an eviction candidate — see §6 open question.)
- **No generation counters on DocId.** Monotonic-never-reused `u64` already kills ABA (per the audit). An evicted-then-re-requested id returns `DocNotFound`, never a wrong doc.

---

## 5. Implementation surface

### 5a. Where it lives

The registry moves out of `crates/ffi/src/handle.rs` into a host-testable **`CoreRuntime`** in `crates/core` (the audit's Phase-2 state model). Eviction is pure-logic Rust there — fully unit-testable on the host with no FFI/VM, which matters for the validation mandate (this is exactly the "pure-logic / model / FFI behavior ⇒ write the behavior test, self-validate" tier in `CLAUDE.md`). The FFI/serve tiers become thin shims over it.

```
crates/core/src/runtime.rs   (new)
  CoreRuntime {
    docs: RwLock<HashMap<DocId, Arc<Mutex<DocumentSession>>>>,
    pinned: RwLock<HashSet<DocId>>,
    meta: RwLock<HashMap<DocId, DocMeta>>,   // last_touched, estimated_bytes
    budget: EvictionBudget,                  // config (§5c)
    next_id: AtomicU64,
  }
  DocMeta { last_touched: Instant, estimated_bytes: usize, pinned: bool }
```

`DocumentSession` is today's `CsvSession`, generalized later to other doc kinds; `estimated_bytes()` is a cheap accessor over the `TableArena` (it already knows its buffer + offset-table sizes).

### 5b. API (the contract surface)

Host → core (new):

| Method | Purpose |
|--------|---------|
| `runtime_open(bytes) -> DocId` | replaces `session_open`; inserts, runs **admission eviction** (evict LRU-unpinned until the new doc fits the budget) *before* returning |
| `runtime_set_pinned(doc_id, bool)` | host marks active/visible (and unsaved-edit) docs; pinned docs are eviction-exempt |
| `runtime_touch(doc_id)` *(implicit)* | every `runtime_*` call on a doc bumps `last_touched`; no explicit call needed |
| `runtime_close(doc_id)` | explicit free (replaces `session_free`); idempotent |
| `runtime_stats() -> { doc_count, total_bytes, budget, [{doc_id, bytes, pinned, idle_ms}] }` | the enumeration + size hook; diagnostics / memory HUD / "close others" |

Core → host (new signal):

- Any `runtime_*` call against an evicted/unknown id returns **`DocNotFound`** (a recoverable status in the slimmed error model, `synthesis.md:115`). The host's wrapper catches it and **rehydrates**: re-`open` from the bytes/path it still holds, swap in the new DocId, retry once. The user sees nothing. This rehydration logic lives in the Swift `CsvSession` wrapper (and the future remote client), not the core.

Eviction trigger points:
1. **Admission** (on `runtime_open`): evict LRU-unpinned until `total_bytes + new_doc ≤ budget.max_bytes` and `doc_count < budget.max_count`. If even after evicting everything unpinned it still doesn't fit, the doc is admitted anyway (we never refuse to open what the user asked for) but a `runtime_stats` over-budget flag is set — pinned docs alone can exceed budget, and that's the host's signal to close tabs.
2. **Idle reaper** (background, or lazy on each `open`/`stats`): evict any unpinned doc with `idle_ms > budget.ttl_ms`. This is the orphan backstop for a remote client that died without `close`.

### 5c. Config knobs (`EvictionBudget`)

```rust
struct EvictionBudget {
    max_bytes: usize,   // hard resident-document RAM ceiling (the primary bound)
    max_count: usize,   // secondary guard against many-tiny-docs map bloat
    ttl_ms:    u64,     // idle reaper horizon; 0 = disabled (no TTL, byte+count only)
}
```

Defaults are owner-set (§6). All three overridable at runtime via a `runtime_configure` call so the host can tune per-device (a 96 GB Mac Studio vs an 8 GB MacBook Air) — and so a test can set a tiny budget to exercise eviction deterministically.

### 5d. How the Swift side signals active/pinned

The app already owns tab/focus state. The wiring:
- On tab focus change → `runtime_set_pinned(visibleDocId, true)` for the foreground doc (and any doc with unsaved core-side edits); `set_pinned(false)` for ones scrolled out of view but still open.
- The Swift `CsvSession` wrapper keeps the original bytes/path (it already receives them at `init`) so it can transparently rehydrate on `DocNotFound`.
- ARC `deinit` still calls `runtime_close` — eviction is *additive* to explicit close, not a replacement. In-process, ARC remains the common-case GC; eviction is the safety ceiling and the orphan reaper. Remote, eviction *becomes* the primary GC.

### 5e. Testability (the change → tests mandate)

All host-testable pure logic (no VM, no WebView):
- LRU order under mixed pin/touch sequences; admission eviction respects the byte budget; pinned doc is never evicted even when it alone exceeds budget; `DocNotFound` returned for an evicted id; idle reaper drops only `idle > ttl` unpinned docs; `runtime_stats` totals match resident reality; budget=0/ttl=0 edge cases.
- A **teeth** test: set a tiny `max_bytes`, open three docs, assert exactly the LRU-unpinned one is gone and its id returns `DocNotFound` — a test that fails the moment eviction regresses to no-op.
- Swift-side: the wrapper's rehydrate-on-`DocNotFound` retry path (model-level, host-testable per `CLAUDE.md`).

---

## 6. What needs the OWNER's decision vs. what I can just build

### Build without asking (engineering, not product)

- The `CoreRuntime` registry, `DocId`, pinning API, idle clock, size estimation, the LRU+byte+count+TTL eviction *mechanism*, `DocNotFound` + host rehydration, `runtime_stats`, and all the tests. These are the audit-sanctioned "hooks + policy mechanism" — pure engineering with one clearly-correct shape. (Spike + design auto-approved per the SOP; mechanism choice is Option 4 above.)

### Needs the owner — these are **values / product**, not engineering:

1. **The default budget values.** What is the resident-document RAM ceiling? Proposed defaults to ratify or override: `max_bytes = 512 MiB`, `max_count = 64`, `ttl_ms = 0` (disabled by default in-process; enabled — e.g. 10 min — only for the remote/serve tier where orphan reaping matters). These are the one true "value choice" the audit parked.
2. **Eviction-vs-tab UX semantics.** When a doc *behind a still-open background tab* (not the active one) is evicted to honor the budget, what does the user experience on return to it — a transparent silent rehydrate (re-parse from disk, brief spinner), or never (i.e. **all open tabs are pinned**, so eviction only ever touches docs with no visible tab — recent-files cache, pre-parse, etc.)? This is the "evicting open-tab state is a UX call" the audit flags. My recommendation: **all open tabs pinned ⇒ eviction never surprises a visible tab; only off-screen retained docs are candidates.** Owner to confirm.
3. **Unsaved-edit docs.** If/when the core holds doc state with edits not yet persisted by the host, eviction would be data loss. Policy: such docs are **always pinned** (never evictable) and the host is responsible for flushing before unpinning. Owner to confirm this is the desired contract (vs. core-side persist-on-evict, which I recommend against in §4).

None of these block landing the mechanism — it ships with safe defaults behind `runtime_configure`, and the owner's answers set the shipped defaults and the pin-all-tabs flag.

---

## 7. Recommendation in one line

Build the **hybrid byte-budget + count-cap LRU with host pinning of active/visible (and unsaved) docs, a TTL idle-reaper as the remote-orphan backstop, and recoverable `DocNotFound` rehydration** — it is the only option that simultaneously caps RAM, never surprise-closes a visible doc, stays recoverable, and survives the move to a remote core; ship the mechanism + tests now, and get the owner to ratify three values: the default budget numbers, "all open tabs are pinned", and "unsaved-edit docs are always pinned".
