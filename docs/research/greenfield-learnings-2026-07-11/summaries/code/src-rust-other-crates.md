# Rust Core — Serve, FFI, Highlight, Web, TUI, PM Crates

## File Inventory

### Workspace Root

**rust-core/Cargo.toml** (~167 LOC) — workspace metadata, shared deps, profiles, lints
- notable: resolver="3", 7 member crates, 3 default members (core/ffi/serve). Pinned exact versions throughout. Custom profiles: dev (debug), release (size-opt + panic=abort), dist (speed, panic=unwind for GUI), test (line-tables-only for 5% cold-compile speedup). Workspace lints enforce no-panic/no-unwrap/no-slicing in core; ffi opts out of unsafe forbid and re-enables unsafe with strict guidance.
- carry: KEEP — robust pattern for deps, profiles, and lint inheritance. The size/speed/test profile ladder is well-motivated.

---

### Serve Crate (daemon, machine API, protocol v1)

**rust-core/crates/serve/Cargo.toml** (~49 LOC) — declares mdv-serve binary & lib, zero external deps (std-only)
- notable: depends on core/ffi/highlight + workspace serde. No ratatui/crossterm/tree-sitter here (those live in tui/highlight only, so they never enter the app build). Mirrors workspace lints locally (no inheritance due to ffi precedent).
- carry: KEEP — elegant scoping keeps the binary lean.

**rust-core/crates/serve/src/lib.rs** (~50 LOC) — frame read/write helpers
- notable: thin; exports 7 modules + two simple u32-LE length-prefixed frame I/O helpers. read_frame tolerates clean EOF; write_frame enforces u32 length ceiling.
- carry: KEEP — clean framing seam.

**rust-core/crates/serve/src/main.rs** (~151 LOC) — daemon lifecycle, threading, idle ticker
- notable: unix socket listener, launchd activation support (TSK-1553: launchd owns the socket, hands the fd; single-instance guaranteed). Per-minute idle ticker for launchd-only (self-bound runs never self-exit). Retire watcher (TSK-1555) for version handovers. ACTIVITY_GEN atomics track per-connection state to reset idle accumulation on disconnect. Connection cap (8) + over-cap hangup (no buffering).
- carry: KEEP — well-structured lifecycle management. The launchd integration pattern (optional activation fd + self-bind fallback) is production-grade.

**rust-core/crates/serve/src/envelope.rs** (~554 LOC) — protocol v1 hand-rolled MessagePack codec
- notable: hand-rolled MessagePack at the byte level (not rmp-serde) because (a) `bin` family for opaque bodies, (b) unknown-key TOLERANCE for forward compat. Request {id, method, body, optional-aux}, Response {id, body-xor-error}, Event {sub, seq, kind, body}. Encoding pushes fixstr/uint/bin directly; decoding uses a cursor + full skip() for unknown keys. TSK-575 allows one guarded cast (v < 0x80 → u8). Round-trip tests included.
- carry: KEEP — hand-rolled is justified here. The protocol is small + fixed, and forward-compat tolerance is a wire contract that serde doesn't handle naturally.

**rust-core/crates/serve/src/serve.rs** (~839 LOC) — connection handling, method dispatch, duplex loop
- notable: hello first (version check hard-close), then duplex loop (requests inline + watcher thread pushes events via shared Mutex). method_fn dispatch table routes to core *_wire functions directly (no FFI hop). version skew handover (TSK-1555): newer client can send daemon.retire to trigger respawn. Capabilities mask advertised per-connection (FS/GIT/SEARCH conditional on config). Frame cap 16 MiB. Watcher ticks at MIN_TICK_MS, debounces per-sub events.
- carry: KEEP — clean duplex architecture. The version-skew arbiter (version check + retire handover) is a solid pattern for daemon updates.

**rust-core/crates/serve/src/fs.rs** (~418 LOC) — filesystem family (stat/read/readdir)
- notable: FsCtx holds root + claude_dir, cloneable Arc. Dispatch routes fs.* methods. Methods are all GET (readonly); no write/delete. Path traversal guarded. claude_dir scanned for transcript .jsonl files (transcript.list capability).
- carry: KEEP — simple, readonly-only posture is safe.

**rust-core/crates/serve/src/git.rs** (~406 LOC) — git family (head/status/branches/log)
- notable: git.* dispatch methods; calls git CLI (not libgit2). All read-only. Parses git output deterministically.
- carry: KEEP — CLI parsing avoids a native dep; fine for a daemon that's not performance-critical.

**rust-core/crates/serve/src/search.rs** (~400 LOC) — cross-file search (TSK-656)
- notable: search.files method scans a root directory recursively, applies find_engine (the core's regex engine) per file, returns matches. Bounded by result count ceiling. Uses regex-lite (already a core dep).
- carry: KEEP — leverages the core's search logic.

**rust-core/crates/serve/src/watch.rs** (~818 LOC) — subscription hub (fs.watch / transcript.follow)
- notable: WatchHub per-connection; fs.watch subscribes to a path, transcript.follow subscribes to transcript changes. Watcher thread ticks MIN_TICK_MS, debounces per-subscription, emits events. Uses notify crate (for FS changes) + a manual transcript log reader.
- carry: REDO — pull deps first; check if notify is pinned/minimal. The watcher pattern is sound but notify is a heavy dep to audit.

**rust-core/crates/serve/src/lifecycle.rs** (~383 LOC) — daemon lifecycle (idle, retire, version handover)
- notable: IDLE_THRESHOLD_MS, idle_tick decides exit eligibility. retire_requested flag + attached_versions registry for version-skew handling. Stateless; all I/O done by main.rs.
- carry: KEEP — clean stateless functions.

**rust-core/crates/serve/src/transport.rs** (~250 LOC) — protocol helpers
- notable: likely frame/error encoding helpers. Part of the protocol surface shared with clients (tui/web thin-client mode).
- carry: KEEP — centralizes the protocol wire format.

**rust-core/crates/serve/src/transcript_list.rs** (~180 LOC) — transcript discovery
- notable: TranscriptCtx scans claude_dir for .jsonl files, caches the list. transcript.list method returns the index.
- carry: KEEP — simple.

**rust-core/crates/serve/src/bin/perf_floor.rs** — performance baseline harness
- carry: KEEP — benchmarking tool, not shipped.

---

### FFI Crate (extern "C" boundary, unsafe + symbol exports)

**rust-core/crates/ffi/Cargo.toml** (~63 LOC) — C ABI wrapper
- notable: crate-type = [cdylib, staticlib, rlib]. Does NOT inherit workspace lints (cargo #13157 conflict resolution). Re-declares the no-panic/no-unwrap set locally. build.rs runs cbindgen for header generation. dev-dep: serde (test-only, canvas M0 smoke). build-dep: cbindgen.
- carry: KEEP — the workaround for lint inheritance is solid.

**rust-core/crates/ffi/src/lib.rs** (~300+ LOC header, total ~1000 LOC) — C ABI contract, capability bitmap, dispatch
- notable: Every extern "C" fn wrapped in ffi_guard! (catch_unwind). OUT-PARAMS for payloads (errors never mixed with status). MdvStatus enum (repr(C)). Wire protocol v2 check (hard-close on version skew). Capability bitmap (TSK-634): 16 bits assigned for engine families (CSV, diff, hex, indent, CM apply, find, markdown, transcript, fuzzy, highlight, delta-apply, doc-store). Thin-waist envelope dispatch (TSK-580): ONE versioned mdvcore_call entry routing method-id + frame to core logic. Method constants (MDV_METHOD_*) emitted by cbindgen so Swift sees them as #define. Status codes: OK, Panic, WireError, NullArg, HandleDead, Busy, TooLarge. Rich error channel: wire::WireError {code, message, data} frame in out_buf for opt-in diagnostic detail (TSK-577). 
- notable: panic = "abort" on release (size figure); panic = "unwind" on dist (GUI dylib, catch_unwind keeps app alive). The panic strategy split is well-documented.
- notable: mdvcore_add (stage 0 smoke test), mdvcore_abi_version, mdvcore_capabilities runtime checks. Version/capability constants both compile-time + runtime (header compile vs linked library can diverge if VM rsync'd; the runtime checks catch that).
- carry: KEEP — comprehensive. The thin-waist envelope + capability bitmap pattern is production-grade. The panic strategy reasoning is sound.

**rust-core/crates/ffi/src/handle.rs** (~163 LOC) — opaque session handle registry
- notable: TSK-541 fix: instead of raw Box::into_raw (free-vs-call UAF on concurrent free), uses a global Mutex<HashMap<usize, Arc<SessionHandle>>>. Token is `*mut SessionHandle` (opaque to Swift, acts as a key into the registry). lookup clones the Arc (so in-flight calls keep the session alive if a concurrent free races). free removes the entry; idempotent. try_lock (not blocking lock) on calls; returns Busy on contention. Poisoned lock → HandleDead (permanent). Monotonic token allocator (1-based, no wrap reuse).
- carry: KEEP — this is a textbook UAF fix. Arc-cloning under the registry lock is the right pattern.

**rust-core/crates/ffi/src/buf.rs** (~50 LOC likely) — MdvBuf struct + free
- notable: MdvBuf wraps opaque bytes for out-params. mdvcore_buf_free called by Swift to deallocate.
- carry: KEEP — simple memory management seam.

**rust-core/crates/ffi/src/guard.rs** (~100 LOC likely) — ffi_guard! macro
- notable: Macro wrapping extern "C" fn bodies in catch_unwind. Returns MdvStatus::Panic on catch, success status on normal return. Hygiene: catches panics, allows normal Rust errors (Result) to flow as wire errors.
- carry: KEEP — correct pattern.

**rust-core/crates/ffi/src/status.rs** (~40 LOC) — MdvStatus enum (repr(C))
- notable: Maps Rust results to C integer codes. OK, Panic, WireError, NullArg, HandleDead, Busy, TooLarge, probably others.
- carry: KEEP — straightforward.

**rust-core/crates/ffi/src/launchd.rs** (~50 LOC likely) — launchd activation
- notable: launchd_activation_listeners("name") returns listening fds handed by launchd (for socket activation).
- carry: KEEP — thin wrapper.

**rust-core/crates/ffi/src/canvas_handle.rs** (~100 LOC likely) — canvas session handle (similar pattern to SessionHandle)
- carry: KEEP — parallel structure for canvas API.

**rust-core/crates/ffi/build.rs** (~50 LOC) — cbindgen invocation
- notable: Generates C header from Rust #[no_mangle] + struct definitions.
- carry: KEEP — standard cbindgen setup.

**rust-core/crates/ffi/tests/no_panic_lints_gate_*.rs** — lints audit gate
- notable: Proof that the FFI build passes no-panic lints.
- carry: KEEP — gate validation.

---

### Highlight Crate (tree-sitter + all grammars)

**rust-core/crates/highlight/Cargo.toml** (~64 LOC) — tree-sitter + 18 grammar crates
- notable: tree-sitter = "=0.25.10" + tree-sitter-highlight = "=0.25.10" (pinned exactly). Grammar crates: json, rust, js, ts/tsx, java, c, cpp, c#, swift, kotlin-ng, lua, python, bash, yaml, html, css, go, ruby, markdown, xml, sql. All pinned exactly. Depends on core (wire) + serde (payload encode). TSK-660: this crate is NOW part of FFI + merge gate (the app ships treesitter highlighting in its staticlib).
- carry: KEEP — pinned set is production-ready. The grammar crate collection matches the Swift app's 22-language set (owner-approved per TSK-257 park).

**rust-core/crates/highlight/src/lib.rs** (~300+ LOC) — tokenization, grammar registry, TokenKind vocabulary
- notable: TokenKind enum: Keyword, String, Number, Comment, Function, Type, Constant, Variable, Property, Operator, Punctuation, Tag, Attribute, Other (unmapped → unstyled). Process-wide config CACHE (query parse + compile is 10s of ms on big grammars); one entry per (Lang, capture-name-list ptr). configured() fetches or builds + caches. highlight(src, lang) returns flat Span list [start, end, kind]. Languages 24 total. from_extension (case-insensitive) and from_name (host vocabulary → grammar) converters.
- notable: TypeScript + C++ inherit base grammars (JS + C) because tree-sitter-highlight doesn't resolve `; inherits`; we concatenate query strings. Rust gets custom @constant rules for SCREAMING_CASE decls (TSK-1201). Swift comments get explicit rules (TSK-1201). Kotlin has NO bundled query, so a minimal vendor query ships in the crate.
- carry: KEEP — caching strategy is sound. The query inheritance workarounds are correct. TokenKind vocabulary is small + render-agnostic (perfect for 3 front-ends).

**rust-core/crates/highlight/src/runs.rs** (~200 LOC likely) — wire-exposed tokenization (runs_wire)
- notable: FFI-exported highlight_runs method (MDV_METHOD_HIGHLIGHT_RUNS, TSK-660). Returns UTF-16 offsets + TokenKind (the app's wire format). Invoked by app, TUI, web tier.
- carry: KEEP — reusable across all front-ends.

**rust-core/crates/highlight/src/folds.rs** (~200 LOC likely) — code-fold regions (TSK-1202)
- notable: fold_regions wire method. Tree-sitter query over fold.scm capture names. Returns fold region list + nesting depth. Used by CM6 editor (the app's WebView).
- carry: KEEP — integrates with grammar.

---

### Web Crate (std-only HTTP/1.1 server, server-renders HTML)

**rust-core/crates/web/Cargo.toml** (~31 LOC) — declares mdv-web binary, std-only
- notable: depends on core + serve (CoreTransport seam, TSK-1558) + highlight. ratatui NOT here (tui only). Zero external deps except workspace serde/highlight. Does NOT inherit workspace lints (IO-bound server has different panic/unwrap tolerance).
- carry: KEEP — clean separation.

**rust-core/crates/web/src/main.rs** (~2,500+ LOC) — HTTP server, HTML render engine, file nav
- notable: std-only hand-rolled HTTP/1.1 (no hyper/actix/etc). Binds 127.0.0.1 (localhost-only, never exposed). TcpListener + per-connection thread. Per-mode HTML render (text / hex / table / markdown outline / image gallery). Uses core's view::render logic (same shaping as TUI). Syntax highlighting via highlight crate (cached). Asset allowlist (codemirror.js / mermaid.min.js / canvas.js served from static assets dir). Shared WebConfig persistence (~/.textview/wui/config). MRU list for recent files (TSK-234). Request timeout 15s per socket, 10s total for request head. Connection cap 128. Preview cap 1 MiB (per-mode shaping in core). Socket read/write with timeouts (avoid slow-loris/stalled reads pinning threads forever).
- notable: Render scaffold for /surface/editor (CM6 editor mount point, TSK-1507 s1). Asset resolver: CLI --assets flag → env MDV_WEB_ASSETS → walk up repo looking for Sources/ViewerUI/Resources.
- carry: KEEP — the std-only posture is admirable. Hand-rolled HTTP is tight. The scaffold for shared CM6/mermaid/canvas surfaces is elegant (a bridge for agent-testable WebUI across native/web).

---

### TUI Crate (ratatui terminal UI)

**rust-core/crates/tui/Cargo.toml** (~28 LOC) — declares mdv-tui binary, ratatui + crossterm
- notable: depends on core + highlight. ratatui = "=0.29.0" (pinned). Exports crossterm transitively. Does NOT inherit workspace lints (TUI app has different constraints than a pure logic lib).
- carry: KEEP — minimal.

**rust-core/crates/tui/src/main.rs** (~2,000+ LOC) — terminal file browser + viewer
- notable: File nav pane + content viewer (text / hex table / markdown outline). Keys: ↑/↓/j/k move, Enter/l/→ enter, Backspace/h/← parent, x toggle text/hex, n toggle line-numbers, s cycle sort, . toggle hidden, f quick-find, : go-to-line, / in-file find (n/N step, ESC clear), o markdown outline (TSK-1504), g/G top/bottom, PgUp/PgDn scroll, q quit. Per-mode shaping (text / hex / table) via core::view (identical to web front-end).
- notable: Preview struct caches loaded file + shaped View + syntax spans (RefCell memoisation to avoid per-frame re-parse; 200k line ceiling). Per-file metadata: mtime, size (for sort). FilterCache, FindCache, TextBadgeCache per Preview (TSK-544 per-frame optimization: avoid re-scanning per keystroke). Persistent session state (~/.textview/tui/config): cwd + per-tab (path/scroll/mode). Restore tabs on startup (best-effort).
- notable: TestBackend support (--snapshot flag renders one frame to stdout for headless validation).
- notable: Syntax highlight lang via file extension; memoised per-file + checked once at highlight() time.
- carry: KEEP — architecture is sound. The RefCell caching + per-frame keys (filter needle, find query) avoid pathological recompute. The session restore is UX-critical.

---

### PM Crate (project-management event-sourcing + SQLite)

**rust-core/crates/pm/Cargo.toml** (~19 LOC) — rusqlite + serde + rmp-serde
- notable: rusqlite = "=0.39.0" with default-features OFF (no cache/hashlink, SYSTEM libsqlite3). serde + rmp-serde already workspace deps. Isolated from core (which stays sans-IO / wasm-buildable). Inherits workspace lints (no-panic/unwrap).
- carry: KEEP — min-deps posture on rusqlite is excellent. System libsqlite3 (no bundled) is correct.

**rust-core/crates/pm/src/lib.rs** (~300+ LOC) — event-sourcing schema + lifecycle
- notable: Slice 2a (mechanism only; hashes + decision-trace in slice 2b). Schema: event_log (seq/ts/actor_id/actor_kind/event_type/subject_id/reason/payload-blob), work_item (id/title/state/created_seq/updated_seq/claimed_by), wi_edge (from/to/kind edges). WorkItemEvent enum: Created, StateChanged (with reason), EdgeAdded (event-sourced). State enum 10 classes: Proposed, Ready, Active, Parked, ClaimedDone, VerifiedDone, Closed, Rejected, Abandoned, AssumptionsInvalidated (terminal: Closed/Rejected/Abandoned). can_transition(from, to) shape-checks legal edges (v2 §2.2 table). ActorKind: Human/Agent/System (0/1/2 codes). can_actor_transition(actor, from, to) gates by actor kind (e.g. ClaimedDone→VerifiedDone is System only, the verifier ≠ doer guard). PmError: Sqlite / UnknownItem / UnknownState / IllegalTransition.
- carry: KEEP — event-sourcing pattern is production-solid. The actor-kind gating (encoded as data, can't be skipped even if an autonomous loop tries) is a strong safety boundary.

---

## Module Summary

This slice covers the **remote/machine API layer** (serve daemon) + **C FFI boundary** (ffi) + **front-end support** (highlight for syntax, web/tui for browsing) + **project-management store** (pm for event sourcing).

**Serve** is a Unix-socket daemon implementing protocol v1 (hand-rolled MessagePack + unknown-key tolerance). It routes engine methods (the core's wire functions) directly and adds server-only capabilities (fs, git, search, transcript discovery, subscriptions via a per-connection watcher hub). Lifecycle: launchd activation + self-bind fallback, per-minute idle ticker (for respawn), version-skew arbiter (retire handover for daemon updates). Duplex loop: requests inline, events pushed by watcher threads. Zero external deps (std-only).

**FFI** is the unsafe `extern "C"` boundary wrapping the pure core. Every fn guarded by catch_unwind. OUT-PARAMS for payloads. Capability bitmap (16 bits, ABI-stable) gates feature families. Thin-waist envelope dispatch (one versioned mdvcore_call entry). Wire protocol v2 with hard-close on skew. Opaque session handles via Arc-backed registry (fixes TSK-541 UAF). Status codes (OK, Panic, WireError, …) + rich error detail in out_buf (TSK-577). Panic strategy: abort on release (size), unwind on dist (GUI dylib). Two profiles for test/CI.

**Highlight** wraps tree-sitter + 18 grammar crates (24 languages, coverage parity with the Swift app). Process-wide cache of compiled queries. TokenKind vocabulary (14 categories) is render-agnostic. Query inheritance workarounds for TS/C++ (tree-sitter doesn't resolve `; inherits`). Custom rules for Rust const/Swift comments. Kotlin minimal query vendor. Now part of FFI + merge gate (app ships static grammars).

**Web** is a std-only HTTP/1.1 server rendering HTML server-side (no JS framework). Localhost-only, single-user, read-only filesystem browsing. Per-mode shaping (text/hex/table/outline/gallery) identical to TUI — both consume core::view. Syntax highlighting via highlight crate. Asset allowlist for shared CM6/mermaid/canvas surfaces (TSK-1507 s1). Session persistence (~/.textview/wui/config). Request/socket timeouts to prevent slow-loris pins. Connection cap 128. Preview 1 MiB.

**TUI** is a ratatui terminal browser. Same core::view shaping as web. File nav + content pane (4 modes: text/hex/table/outline). Syntax via highlight crate, memoised per-file. RefCell caches (highlight spans, filter matches, find hits) avoid pathological per-frame work. Persistent session (cwd + per-tab state). TestBackend snapshot mode for headless validation.

**PM** is an event-sourced SQLite store (slice 2a mechanism; hashes/decision-trace deferred). Append-only event log + deterministic projection. State machine 10 classes, shape-valid transitions. Actor-kind gating (Human/Agent/System): prevents an agent from auto-admitting or self-verifying, even if instructed. Use case: autonomous task lifecycle with human gates encoded as data.

---

## Patterns Worth Porting

### 1. Hand-rolled protocol codec (envelope.rs)
**File:** `rust-core/crates/serve/src/envelope.rs` (554 LOC)

**Pattern:** Hand-roll a MessagePack codec (not rmp-serde) when the protocol is small + fixed + requires unknown-key TOLERANCE for forward-compat. Cursor-based decoder, explicit skip() for unrecognized keys. Result: protocol extensibility without deps.

**When:** Forward-compat is a wire contract, not an afterthought. Small fixed protocol (ours: fixmap/fixstr/uint/bin only). Unknown keys are *expected* (a newer client sending a field an older server doesn't know).

**Why:** serde's default error on unknown keys breaks forward compat. rmp-serde's `ignore_unknown` workaround requires `serde_bytes` (new dep). Hand-rolling avoids both.

### 2. Zero-external-deps front-ends (web, tui)
**Files:** `rust-core/crates/web/src/main.rs`, `rust-core/crates/tui/src/main.rs`

**Pattern:** Web: std-only HTTP/1.1 server, hand-rolled HTML render. TUI: ratatui (the lighter choice; crossterm only, not termion/winit). Both reuse core::view shaping for text/hex/table/image preview modes.

**Why:** Minimizes supply chain. Web's hand-rolled HTTP is <2500 LOC and the protocol is trivial (no streaming, no complex routing). TUI's ratatui is the Rust consensus for terminal UI.

**Rebuild note:** If adding more front-ends (desktop native, mobile), push the core::view shaping deeper so each can consume it without duplicating the text/hex/table logic.

### 3. Process-wide config cache (highlight.rs)
**File:** `rust-core/crates/highlight/src/lib.rs` (~40 LOC key pattern)

**Pattern:** Parse expensive config (grammar query compilation) once, store in static Mutex<HashMap<key, Arc<value>>>. Cache key includes pointer identity of const arrays (`names.as_ptr() as usize`), leveraging the fact that 'static strings never move. Accessor checks cache first, builds + inserts on miss, returns Arc clone.

**Why:** Tree-sitter query compilation is tens of ms on large grammars. No cache = tens of ms per tokenize (per HTTP request, per TUI render). One cache per (language, capture-name-set identity) = small, deterministic key space.

**Rebuild note:** Same pattern works for any expensive-to-compute config (regex compilation, grammar loading, etc.).

### 4. RefCell per-frame memoization (tui main.rs)
**File:** `rust-core/crates/tui/src/main.rs` (~170 LOC Preview struct)

**Pattern:** Cache computed results (syntax highlighting, table filter matches, text metrics) in RefCell. Fill on first access, reuse until the key changes (e.g., filter needle). Borrow discipline: fill is `borrow_mut` (never coincides with outstanding `Ref`); each render computes keys BEFORE reading cache.

**Why:** TUI renders every keypress (no vsync debounce). Text file 200k lines × per-frame re-tokenize = unusable. RefCell + key-tracking avoids re-parse if the key (file path, input bytes) hasn't changed.

**Rebuild note:** Essential for snappy TUI performance. Not needed for web (serves one file per request, can afford compute per request).

### 5. Arc-backed registry for handle UAF fix (ffi/handle.rs)
**File:** `rust-core/crates/ffi/src/handle.rs` (~163 LOC)

**Pattern:** Instead of raw Box::into_raw pointer, wrap a global Mutex<HashMap<usize, Arc<T>>>. Allocator hands Swift an opaque pointer (cast from usize key). Calls lookup the key, clone the Arc (Arc stays alive for the call even if free races). Free removes the entry; the Arc drop is deferred. Monotonic token allocator prevents UAF via token reuse.

**Why:** TSK-541: raw Box::into_raw + concurrent free-vs-call = use-after-free. The try_lock (not blocking) + Busy status also enforces single-writer (misbehaving multi-threaded caller is rejected, not silently serialized).

**Rebuild note:** This is a textbook solution to the C-to-Rust handle-lifetime problem. Use whenever a C caller holds an opaque Rust object handle.

### 6. Thin-waist envelope dispatch (ffi/lib.rs)
**File:** `rust-core/crates/ffi/src/lib.rs` (~300 LOC header)

**Pattern:** ONE versioned mdvcore_call(method_id, req_frame, aux_frame, out_buf) entry point. Method constants (MDV_METHOD_*) emitted by cbindgen as `#define`. Capability bitmap (16 bits, ABI-stable) gates features above wire version. Rich error channel: wire::WireError {code, message, data} frame in out_buf (backward-compat; opt-in by callers).

**Why:** Reduces symbol bloat (no per-feature extern "C" fn). Wire version = "can we talk", capabilities = "which features exist". Decouples feature shipping from wire protocol bumps.

**Rebuild note:** As the app gains features, new methods land in the dispatch table + capability bitmap, not as new .so symbols.

### 7. Event-sourcing lifecycle gates (pm/lib.rs)
**File:** `rust-core/crates/pm/src/lib.rs` (~100 LOC State/ActorKind)

**Pattern:** State machine with shape-valid transitions (can_transition) + actor-kind gating (can_actor_transition). Rules encoded as data (state ↔ allowable actor kinds per edge), not code paths. Terminal states trap outgoing edges. Reason field required on state changes (audit trail). Edge records are event-sourced (immutable log).

**Why:** Autonomous task lifecycle with human gates that **cannot be skipped**. Even if an agent is instructed to self-verify (ClaimedDone → VerifiedDone), the gate function returns false and the transition is rejected before touching the log.

**Rebuild note:** If adding autonomous task routing, this pattern ensures no agent can escape the human gates (even under explicit misconfiguration or exploit attempt).

### 8. Capability bitmap + wire version split
**File:** `rust-core/crates/ffi/src/lib.rs` (~60 LOC const definitions)

**Pattern:** MDV_WIRE_VERSION (u32): frozen, bumped only on breaking wire format changes. MDV_CAPABILITIES (u64): append-only feature bitmap, bits pre-assigned for planned features (even if unimplemented). Runtime checks: mdvcore_abi_version() returns the linked library's wire version; mdvcore_capabilities() returns linked capabilities.

**Why:** Decouples wire breakage from feature shipping. A client built against a newer header can degrade gracefully against an older library (the remote `mdv-serve` scenario: server may be older than the app).

**Rebuild note:** When porting engines or adding features, pre-assign a capability bit (never renumber existing bits). Build your gating code before the feature lands.

---

## Anti-Patterns / Regrets

### 1. Notify crate (watch.rs) — heavy dep, needs audit
**File:** `rust-core/crates/serve/src/watch.rs`

**Issue:** Uses notify crate for filesystem event subscriptions. Audit burden for a critical daemon path. No special justification over simpler polling or inotify wrapper.

**Lesson:** Even small-seeming additions to the serve daemon (which sits in the critical path between Swift and the core) deserve scrutiny. Consider: is polling acceptable? Can we wrap a system call directly?

### 2. Workspace-lint inheritance workaround (cargo #13157)
**File:** `rust-core/crates/ffi/Cargo.toml`

**Issue:** FFI must opt OUT of `unsafe_code = "forbid"` (the crate IS the unsafe edge), but cargo doesn't allow mixing inherited + local lints. Result: manual re-declaration of the workspace lint set in ffi Cargo.toml, duplicating the source of truth.

**Lesson:** Not a regret per se, but a limitation to watch for in the rebuild. If cargo #13157 is fixed, the duplicate lints should be removed.

### 3. Query inheritance workarounds (highlight.rs)
**File:** `rust-core/crates/highlight/src/lib.rs` (~30 LOC)

**Issue:** tree-sitter-highlight doesn't resolve `; inherits` directives in highlight queries. For TypeScript/C++, we manually concatenate the base (JS/C) query string with the derived one. This is fragile if upstream grammars change their inheritance structure.

**Lesson:** If tree-sitter-highlight ever supports inheritance, simplify these cases to drop the base query string concat.

### 4. Kotlin minimal custom query
**File:** `rust-core/crates/highlight/src/lib.rs` (KOTLIN_HIGHLIGHTS const)

**Issue:** tree-sitter-kotlin-ng ships NO bundled highlights.scm query. We vendor a minimal one. If upstream adds a query, we should prefer theirs (if it's good).

**Lesson:** Keep an eye on the grammar crate. If a query appears, test + migrate.

### 5. Hand-rolled HTTP (web/src/main.rs) — maintenance burden
**File:** `rust-core/crates/web/src/main.rs` (~2500 LOC)

**Issue:** Implementing HTTP/1.1 from scratch avoids a dep, but introduces bugs only HTTP libraries catch (chunked encoding, persistent connections edge cases, content-length validation). The owner chose this for minimal-deps posture, but future maintainers may struggle.

**Lesson:** Document the edge cases that drove the hand-roll decision. If the rebuild adds a web tier, measure the cost of a lightweight HTTP lib (hyper-lite, httpwg) against the maintenance burden of the hand-roll.

---

## Gotchas & Surprises

### 1. Panic strategy split: abort vs unwind
**Why it matters:** The release profile uses `panic = "abort"` (size optimization for a CLI daemon). The dist profile (which would ship in a macOS GUI dylib) uses `panic = "unwind"` so the ffi_guard's catch_unwind can keep the app alive. If you rebuild the dylib without flipping panic=unwind, catch_unwind becomes a no-op and a core panic KILLS THE APP.

**Fix:** Verify the profile. If building a GUI dylib, ensure `panic = "unwind"` is set.

### 2. Launchd socket ownership (main.rs idle ticker)
**Why it matters:** The daemon's idle-exit logic (exit after N minutes of inactivity) is ONLY safe under launchd (which respawns on the socket it owns). A self-bound run MUST NEVER idle-exit (nothing would respawn it; the socket file is abandoned). The code checks the ListenerOrigin and skips the idle ticker for self-bound runs. But if launchd logic is broken or omitted, the daemon silently idles out and the socket becomes unresponsive.

**Fix:** Test both activation paths (launchd + self-bind). Verify the idle ticker only runs when origin == Launchd.

### 3. Version-skew arbiter reads exactly ONE frame (serve.rs)
**Why it matters:** After a version-skew error response, the daemon reads EXACTLY ONE more frame to see if the client is newer and sending daemon.retire (the handover). If the client sends anything else (or two messages), the daemon immediately closes. This is intentional (old clients get hard-close; newer clients get ONE grace read). But if you modify the retire protocol or add another version-skew frame type, the one-frame limit becomes a gotcha.

**Fix:** Keep the retire protocol as-is. If adding a new recovery mechanism, document the one-frame limit clearly.

### 4. Forward-compat tolerance is a wire contract
**Why it matters:** The envelope decoder skips unknown keys. This means a newer server sending a field a older client doesn't know won't break the old client (it sees unknown key, skips it, continues). But the INVERSE (older server, newer client) can break: if the newer client REQUIRES a field the older server doesn't send, the client fails. Be explicit about required vs optional in documentation.

**Fix:** In the protocol docs, mark each field as required/optional. Test both directions (old→new, new→old).

### 5. Arc cloning under registry lock (ffi/handle.rs)
**Why it matters:** The Arc clone happens INSIDE the registry's Mutex lock (line 119 in handle.rs: `cache.get(&token).cloned()`). If an Arc with a large Drop (e.g., a huge CsvSession) is the last ref, the drop runs inside the lock and blocks all other frees/lookups. For a session with massive buffers, this could be a performance cliff.

**Fix:** If sessions grow large, consider taking the Arc OUTSIDE the lock or deferring the drop. Measure before optimizing (the current code is correct; this is only a concern if drop becomes slow).

### 6. Event-sourced edges are immutable, but enforcement lives at the insert layer
**Why it matters:** In pm.rs, wi_edge records are INSERT-only (no deletes). But if someone bypasses the append() function and writes to the db directly, edges can be deleted. The immutability is an API contract, not a database constraint.

**Fix:** Add CHECK or TRIGGER constraints (slice 2b future work) to make edges truly immutable at the db layer.

---

## Rebuild Notes

### If Building This Capability Fresh: Approach & Boundaries

#### Serve Daemon (Remote Protocol)
**Starting point:** The protocol v1 (envelope.rs) is the foundation. Hand-roll stays justified if forward-compat is a requirement.

**Design upfront:**
- Capability bitmap + version scheme (separate wire version from features).
- Subscription model (do you need push events, or is polling acceptable?).
- Socket activation strategy (launchd vs self-bind; affects idle-exit logic).
- Statelessness (serve carries NO doc state; that's future S8). Keep method dispatch stateless.

**Boundaries:**
- Daemon is I/O bound. Serve engine methods direct; don't add extra I/O inside the daemon.
- Fs/git are readonly. Enforce this in the dispatch layer, not per-method.
- Transcript discovery is scoped to one claude_dir (not recursive into subdirs of subdirs).

#### FFI Layer (C Boundary)
**Starting point:** The handle registry (Arc-backed, no raw pointers) + thin-waist dispatch (one versioned entry point) + capability bitmap.

**Design upfront:**
- Settle on panic strategy for your target (GUI app → panic=unwind + catch_unwind keeps it alive).
- Capability bits: pre-assign all planned features upfront, even if not implemented yet.
- Status codes: decide which errors are retryable (Busy, TooLarge) vs permanent (WireError, Panic).
- Rich error channel: if the host wants diagnostic detail, reserve out_buf space for a wire::WireError frame.

**Boundaries:**
- FFI wraps the core; the core is the single source of truth (no logic duplication between C boundary shims).
- Handles are opaque on both sides (Swift never dereferences, Rust never hands raw *T pointers).

#### Highlight Layer (Syntax + Rendering)
**Starting point:** TreeSitter grammar ecosystem + TokenKind vocabulary (small, render-agnostic).

**Design upfront:**
- TokenKind vocabulary: decide once, make it language-agnostic (our 14 categories work for 24 languages).
- Cache granularity: per-(lang, capture-names ptr) is fine; adding per-file memoization is the renderer's job (TUI's RefCell pattern).
- Grammar set: approve the full set upfront; adding later breaks protocol expectations.

**Boundaries:**
- Highlight is pure logic (no I/O). The grammar crates are C-binding wrappers (unsafe, but isolated).
- Query customizations (Rust @constant, Swift comments) are small + localized; document why each exists.

#### Front-Ends (Web, TUI)
**Starting point:** Core::view shaping (text/hex/table/outline/image) is the shared spine. Render engines (HTML generator, ratatui drawing) are front-end specific.

**Design upfront:**
- Reuse core::view exactly (no drift between web/TUI/future front-end). Spec it in tests so a regression is caught.
- Session persistence: decide per-front-end (TUI saves cwd + tabs; web saves root dir + theme; future native app saves window size).
- Cache strategy: RefCell per-frame (TUI) vs per-request (web). Measure if you add more front-ends.

**Boundaries:**
- Each front-end has its own config path (TUI: ~/.textview/tui/config, web: ~/.textview/wui/config).
- No front-end talks to another (web doesn't call TUI logic; they share the core, not each other).

#### Project Management (Event Sourcing)
**Starting point:** Append-only event log + deterministic projection. State machine with actor-kind gating.

**Design upfront:**
- State classes: keep small + meaningful (10 is good; 50 is complexity). Every state should be reachable + have a clear exit.
- Actor kinds: decide who can transition where (owner/human auto-admit? agent never self-verify?). Encode as data (can_actor_transition) so it can't be skipped.
- Event payload schema (MessagePack): approve once. Additive changes to the schema (new fields) are OK; removals break old log readers.

**Boundaries:**
- Event log is immutable (append-only). Projection is derived (can be recalculated from the log). Never mutate the log directly; always append.
- Edges are sourced (INSERT into event_log, then INSERT into wi_edge as a projection). If you add a constraint (wi_edge is immutable), add it to the event handler, not the db schema alone.

#### What to Design Up Front (Before Implementation)
1. **Protocol versioning strategy:** wire version vs capabilities bitmap. How far can clients degrade on old servers?
2. **Handle lifetime model:** who allocates, who deallocates, what happens on concurrent access?
3. **Error semantics:** which errors are retryable? Which require a hard re-attempt?
4. **Persistence:** for front-ends, where does config live? Single file or per-type?
5. **Scaling:** can you test with 10 MiB files? 100 MiB? What breaks?
6. **Panic recovery:** if the core panics, does the app crash or recover? How does the host know?

#### What to Defer
1. **Hashes + tamper-evidence (pm slice 2b):** not needed for MVP. Audit trail (reason field) is enough for slice 2a.
2. **Daemon session state (S8):** start serve as stateless. Doc state comes later.
3. **LSP pipe family (TSK-659):** reserved in capability bitmap, not implemented yet.
4. **Optimize highlights query inheritance:** tree-sitter-highlight may add inheritance support; wait and see.

---

## Summary Table

| Crate | Role | Status | Key Design | Carry/Redo |
|-------|------|--------|------------|-----------|
| serve | Unix-socket daemon, protocol v1 | ~4.5k LOC | Hand-rolled envelope, launchd activation, version-skew arbiter | **KEEP** |
| ffi | C ABI boundary, handles, dispatch | ~1k LOC | Arc registry (UAF fix), thin-waist dispatch, capability bitmap | **KEEP** |
| highlight | Tree-sitter + 24 languages | ~1k LOC | Config cache, TokenKind vocab, query inheritance workarounds | **KEEP** (audit notify dep in serve/watch) |
| web | HTTP/1.1 server, HTML render | ~2.5k LOC | Std-only hand-rolled, shared core::view, asset allowlist | **KEEP** |
| tui | Ratatui terminal browser | ~2k LOC | RefCell memoization, persistent tabs, headless snapshot mode | **KEEP** |
| pm | Event-sourcing + SQLite | ~500 LOC | Append-only log, deterministic projection, actor-kind gating | **KEEP** |

---

**Report generated:** 2026-07-11  
**Codebase snapshot:** post-TSK-1567 (audit complete)
