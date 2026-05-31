# State / Core-UI Architecture — Exploration Log

**Date:** 2026-05-30 · **Status:** 🟡 LIVING — exploration, decisions OPEN, nothing finalized · **Owner:** Jos

> Purpose: preserve the full reasoning from a multi-session design exploration so it survives context compaction. Markers: ✅ converged · 🔶 leaning · ❓ open. This is a thinking record, not a spec.

Companion docs (same branch `docs/reusable-core`):
- `REUSABLE_CORE_STRATEGY_2026-05-30.md` — Rust core / multi-front-end lose-gain + phased plan.
- `CORE_UI_BOUNDARY_AUDIT_2026-05-30.md` — current boundary, what can move to Core, interface options.
- `CORE_LINUX_PORTABILITY_2026-05-30.md` — Linux blockers + costs.
- `CORE_ARCHITECTURE_RESEARCH_2026-05-30.md` — 9-agent web survey of how real editors detach their core (the evidence base below).

---

## 1. The goal

One **reusable core** runnable across: **macOS SwiftUI · browser WebUI · macOS terminal (ratatui) · Linux terminal.** Concrete vision:
- Core running **headless on a Linux box**, full functionality via a **browser**.
- And/or the **same Mac UI in "remote mode"** against that core (possibly over **SSH**).

## 2. The deciding question (❓ still unanswered, gates everything)

**Is the macOS app the product (other UIs nice-to-have) — or is the reusable core the product (Mac app is one client)?** The remote/browser vision implies the latter. This determines whether a core rewrite is worth it.

Sub-decisions still open:
- ❓ Are **Linux + Web committed** targets or aspirational?
- ❓ **Swift-portable-core vs Rust-core?** (The protocol/boundary work is needed *either way*; only the compile blockers + WASM vanish under Rust.)
- ❓ FFI tooling if Rust: `uniffi` vs `swift-bridge`.

---

## 3. What we've CONVERGED on (✅)

### 3.1 The boundary, not the language, is the problem
The boundary audit (validated against code) found ViewerCore is genuinely clean — **only 2 AppKit imports** (`SyntaxTheme`, `FileTreeRecency`), zero SwiftUI. So the obstacle is the boundary's **shape**, not Core's purity.

### 3.2 `DocumentModel` is the real work, and it lives in the UI
`DocumentModel` (~2261 LOC, `@MainActor ObservableObject`, ~81 `@Published`) is **in ViewerUI**, not Core — it's the orchestration *caller*. The months-long work is **extracting the orchestration state machine out of ViewerUI into a headless Core**, not "moving ViewerCore" (mostly already clean).

### 3.3 Two distinct problems behind "stop-the-world" / god-object
- **Main-actor blocking** → UI freezes. Fix: move heavy work off-main. *Orthogonal* to the god object.
- **Republish amplification** → one big `ObservableObject` re-renders broad subtrees. Fix: fine-grained models + direct `@ObservedObject` + narrow version channels. *This* is the god-object problem.
(Both are half-done; the coordinator split + off-main fixes were attacking them.)

### 3.4 Don't rewrite the Mac GUI; never put a process/async boundary on the interactive read path
Field consensus + xi's post-mortem: the UI querying text/cursor/layout it's about to paint must be **synchronous, in-process**. Rewriting SwiftUI/AppKit in Rust = loss. (✅)

### 3.5 Sync, functional, in-process Core API — req/response, NOT single-threaded
- "req/response" = the *shape* (ask → answer), independent of threading.
- **Worker pool under a sync API** → N requests run concurrently; a slow `openDocument(200MB)` doesn't block `tabList()`.
- **Two tiers:** *queries* (cheap, pure, read an immutable snapshot → truly synchronous, no thread hop) vs *commands* (I/O / heavy → dispatched to a worker, answer via completion; UI main thread never blocks).
- **Consistency:** per-document serialization (serial queue/actor per doc) + snapshot reads — same doc ordered, different docs parallel, reads concurrent against immutable snapshots (IntelliJ's read/write model).

### 3.6 Hexagonal ports for what the Core needs from the world
Core calls **synchronous "ports"** the host implements (`read(path)`, `runProcess(argv)`, `watch(path)`, `now()`). Injected at Core init. For **remote**, ports run on the Core's host (the Linux box) — "read file" reads the box's disk. (✅)

### 3.7 The push channel: capability-scoped, LEVEL-triggered subscriptions (not an event bus)
Owner's discomfort — "emitting events not knowing who/when consumed" — is the same discomfort that produced the winning pattern. Resolution:
- The UI **registers callbacks for what it cares about** (capability-gated, LSP-`initialize`-style). Core invokes only registered, declared callbacks → no firehose, no wasted work/wire.
- **"Everything is a request from someone."** A subscription *is* a standing request whose response arrives 0..N times. Even push is req/response-shaped.
- **Level-triggered, not edge-triggered** (matklad's explicit rec): the callback delivers **"here is the current state of X,"** not "X changed by delta Y." Robust to missed messages, reordering, reconnect — a dropped socket just re-delivers current truth.

### 3.8 Two kinds of topic
- **State topic** (level-triggered, coalescing, 1-slot mailbox, "holding" is ~free because Core already holds current truth): git status, diagnostics, disk-changed flag, tab set, *file-changed-underneath → re-snapshot*.
- **Stream topic** (FIFO appends, can't coalesce, bounded buffer + backpressure/budget): terminal output, tail-follow a growing log.
Both via the same `subscribe`; the topic declares its mode. (Answers "snapshot AND update-by-events" — yes, per-topic.)

### 3.9 Ephemeral connection, durable in-Core session (the tmux/mosh/VS-Code-Server model)
The wire is a **DVI cable**; the session lives in Core and outlives the cable.
- **Disconnect:** client shows **cached view, read-only** — can view what's loaded, can't load new / edit. **No offline editing** (explicit non-goal).
- **Reattach:** Core re-delivers current domain state (level-triggered snapshot); client re-applies its own view state. Non-disruptive by construction.
- **Buffer budget:** if reconnect exceeds budget, Core hard-drops the connection's delivery state (reclaims memory, mainly stream buffers); a late reconnect = **clean full snapshot resync** (level-triggered makes a snapshot a valid resync).

### 3.10 Ownership split (the key that makes reconnect non-disruptive)
- **Core owns DOMAIN state:** open documents, content, edit state, git status, the open-tab *set*.
- **Client owns VIEW/ephemeral state:** scroll position, cursor/selection, focused tab, fold state, viewport.
- → "Don't put me in a random place on reconnect" is **true by construction** — scroll never left the client; Core has nothing to lose or guess.

### 3.11 Single-writer, session pinned to one UI (biggest complexity win)
- **One writer per session** for **domain** mutations → deletes the entire collaborative-conflict problem (CRDT/OT — what made xi/Zed/Figma hard).
- **Session definition:** a durable, in-Core bundle of `{open documents + domain state + working context (sidebar root, git roots)}`, owned by **≤1 attached client at a time**. Core hosts **N independent** sessions (one per client).
- **Transfer** = detach UI-A → attach UI-B (B gets the snapshot). Domain state travels; new client supplies its own view state.
- **Sharing a session = explicitly out of scope** (defer collab). 2-3 clients assumed ("famous last words" — acknowledged).
- **Domain vs incidental mutations:** single-writer applies to *domain* mutations (edit, open/close, set git root). *Incidental* writes (telemetry, recents, caches) aren't domain → can be concurrent/local.

### 3.12 Errors
- Command errors → ride the req/response result (sync-ish).
- Subscription errors → a **payload on that subscription**; level-triggering makes it clean (current state of `.diagnostics` *becomes* `.unavailable(reason)`).
- Add a **terminal payload** so a subscription can signal "permanently done/dead" vs "currently erroring."

### 3.13 Transport-agnostic
Same logical `Request → Response` works **in-process (direct call on a worker)** or **over a WebSocket (remote)**. Socket adds request-ID correlation + subscription-ID routing (JSON-RPC-style); Core/UI stay transport-blind. We already have the req/response half: the **MCP stdio server** (`ViewerCore/Automation`) — missing the subscription channel.

---

## 4. What does NOT make sense (rejected, with reasons)

- ❌ **Async core API.** "Async is a complexity multiplier" (xi). Function-coloring contagion; interactive systems must paint even with subqueries pending.
- ❌ **Fire-and-forget edge events into the void.** Unknown consumer/timing → drift, stale highlighting, wasted re-query (matklad). Replaced by level-triggered held state to known subscribers.
- ❌ **A synchronous-blocking boundary stretched over the network.** = xi's exact mistake + Apple's discouraged sync-XPC-proxy. UI freezes on every round-trip. (Remote needs a *different* approach — §6.)
- ❌ **Process/async boundary on the interactive read path.** The one design with a primary-source post-mortem against it.
- ❌ **Rewriting the Mac GUI** (vs. moving the core). Loses native integration.
- ❌ **XPC as the cross-ecosystem boundary.** Apple-only; a browser/Linux/ratatui client can't speak it. Use a portable transport (socket + JSON-RPC / framed binary).
- ❌ **Collaborative/shared sessions now.** Deferred via single-writer pinning.
- ❌ **Offline editing.** Explicit non-goal; connectivity is integral.

---

## 5. The proposed shape (consolidated, 🔶 leaning)

```
Core: hosts N independent single-writer SESSIONS (domain state = the authority).
      Sync req/response API (worker pool + per-doc serialization) for commands + queries.
      Hexagonal sync PORTS for environment (read/runProcess/watch/now) — run on Core's host.
      Subscriptions = capability-scoped, LEVEL-triggered STATE topics (held current truth, ~free)
        + bounded STREAM topics (FIFO, budgeted) for terminal/tail.
Connection: ephemeral (DVI cable). Drop → client cached view, read-only.
            Reattach → snapshot resync + client re-applies its OWN view state.
            Budget expiry → hard drop; reattach = clean full snapshot.
Ownership: Core = domain; Client = view (scroll/selection/focus) → reconnect can't move you.
Writers: one per session; transfer between UIs; no sharing (deferred).
Transport: in-proc direct calls (local) | WebSocket (remote) — Core/UI transport-blind.
```

### Hypothetical interface (exploratory — components / functions / callbacks)

```swift
// What every UI talks to (transport-blind):
struct CoreClient {
    func declare(_ caps: ClientCapabilities)                              // LSP-style; gates work + subscriptions
    func query<Q: Query>(_ q: Q) -> Q.Result                             // TIER 1: instant, pure, snapshot (sync)
    func send<C: Command>(_ c: C, then: (Result<C.Reply, CoreError>) -> Void)  // TIER 2: may defer (worker/socket)
    func subscribe<T: Topic>(_ t: T, _ onChange: (T.Payload) -> Void) -> Subscription  // TIER 3: capability-scoped, level-triggered
}

// What the Core needs FROM its environment (sync ports; run where the Core runs):
protocol HostPorts {
    func read(_ p: FilePath) throws -> Data
    func runProcess(_ argv: [String], cwd: FilePath) throws -> ProcessResult   // git / jq / lsp
    func watch(_ p: FilePath, _ onChange: (FSEvent) -> Void) -> Watch
    func now() -> Date
}

// The Core (no UI framework; portable):
final class CoreEngine {
    init(ports: HostPorts)
    func handle(_ req: Request) -> Reply   // per-doc-serial / cross-doc-parallel; owns sessions + sub registry + capability gate
}
// Topic kinds: .state (snapshot + coalescing updates) | .stream (snapshot + FIFO appends)
```

Two directions, both req/response-shaped: **UI → Core** (commands/queries) and **Core → Host** (ports). The *only* push is **Core → UI** via registered level-triggered subscriptions.

### On threading (✅ resolved)
Don't thread-per-subscription. A **bounded channel holds-until-consumed for free**; producer moves on, consumer reads when ready. State topics = 1-slot coalescing mailbox (~free, Core already holds truth); only stream topics buffer. Rust `std::thread` = OS threads (~2 MiB stack, fine for tens, not thousands; a parked one ≈ its stack, no CPU) — but at 2-3 clients × a few subscriptions, irrelevant; the channel is the right primitive, not the thread.

---

## 6. ❓ OPEN: Optimistic local apply (flagged necessary, not yet designed)

**Why it's likely a necessity (not optional) for the remote path:** the research found *every* system that shipped UI-driving-a-remote-backend uses it — Figma (apply immediately, reconcile), Mosh (predictive local echo), JetBrains Fleet ("execute locally first"), vscode-neovim (handles typing locally to dodge RPC round-trip). Without it, **every keystroke over SSH waits a network round-trip = unusable.**

**Compatibility with our model:** it is *latency hiding while connected*, **not** offline editing. While connected: client applies the mutation to its local projection immediately + renders + sends the command; Core confirms (or corrects); client reconciles. The round-trip still happens — you just don't *block* on it.

**Why single-writer makes it tractable:** collaborative optimistic apply is hard *because* of multiple interleaving writers (needs CRDT/OT). With **single-writer**, the only divergence is "Core transformed my input differently than I predicted" or "Core rejected it" — so reconciliation is mostly just local echo + confirm, not conflict resolution.

**Where it lives (keeps it contained):** optimistic-local is a **remote-transport-adapter concern** + a thin client-side "predictive apply" layer. The **local in-process path never predicts** (the sync call returns instantly). So it does **not** pollute the Core API or the local UI.

**What it costs (the part to think through):**
- The client gains some ability to **predictively apply** a mutation (so the "dumb" projection fattens slightly — it must know the predicted result of a command, at least for cheap mutations like text insert).
- **Reconciliation needs a sequence/version number:** each client mutation gets a `clientSeq`; Core confirms with that seq + resulting authoritative state; client rebases/replaces its optimistic state up to that seq.
- **Likely does NOT need new event *types*** — the confirm/correct is the command's own req/response reply (+ seq), and the level-triggered state topics already deliver "here's the corrected truth." So the addition is **reconciliation + versioning**, not a new firehose. (Verify this assumption when designing.)

**Open questions for optimistic-local:**
- ❓ Which mutations are predicted client-side vs await-confirm (text edit = predict; "open file" = await)?
- ❓ Reconcile granularity: per-command seq + replace, or finer?
- ❓ How does a *correction* render without a visible flicker/jump (ties to view-state ownership in §3.10)?
- ❓ Does prediction require the client to embed a slice of domain transition logic (fattening the projection) — and is that acceptable vs. a tiny edit-only predictor?

---

## 7. Patterns considered + tradeoffs

| Pattern | Reusable core? | Mac | Web | TUI | Verdict for us |
|---|---|---|---|---|---|
| MVC (AppKit) | ✗ | ✓ | ✗ | ✗ | Controllers UI-bound; dead end. |
| MVVM (status quo) | ~ | ✓✓ | ✗ | ✗ | DocumentModel is a giant ViewModel; fine *if* Model is a pure core. |
| MVVM + pure Model ("two models") | ✓ | ✓ | ✓ | ✓ | Practical first step; owner's instinct. |
| **Elm / MVU / Redux (unidirectional, SYNC reducer)** | ✓✓ | ✓ | ✓ | ✓ | **Leaning.** Pure sync `reduce`; Redux = *concept*, build our own ~50 lines, zero dep. (Redux's async is middleware, not the reducer.) |
| CQRS / event-sourcing | ✓✓ | ✓ | ✓ | ✓ | = the Command/Query/Event split; best for remote. |
| TCA (Composable Arch) | ✗ (Swift-only dep) | ✓✓ | ✗ | ✗ | Steal ideas, **don't adopt** (heavy dep, Swift-only, conflicts with Rust-core + minimal-deps). |

**Net lean:** a unidirectional **sync** reducer-core (pure state + sync `reduce` + Hexagonal sync ports + contained-deferral via worker+callback) with thin per-UI projections. "Redux" means the *concept*, built ourselves.

---

## 8. What the field actually does (evidence base — see research doc)

- **In-process interactive path = synchronous.** Zed/GPUI (`read()`/`update()`), CodeMirror 6 (`dispatch(transaction)`), Helix (immutable rope + Transaction + Selection), Scintilla. macOS NSDocument MVC too (but Apple-only).
- **xi-editor = the cautionary tale.** Creator: front-end↔core *process separation* "was not a good idea"; "async is a complexity multiplier"; in-process sync query "would have been quite straightforward." Async was fine only for genuinely-background work (syntax highlight plugin).
- **Async/RPC is reserved for coarse, genuinely-remote/crash-prone seams:** LSP/DAP, network collab, remote-dev backends, plugins. The one split even xi's author endorses = LSP-style.
- **Systems that shipped remote UI-driving (Neovim, VS Code-remote, Jupyter, Figma, JetBrains Gateway/Fleet, tmux/mosh) all obey 4 rules:** (1) one state authority, (2) aggressive batching, (3) coarse semantic seam (workspace/compute vs UI — never per-keystroke RPC), (4) optimistic-local prediction so the UI never blocks.
- **Honest counter to our lean (`contradicts_our_lean`):** sync is well-supported for the *in-process* seam but **challenged for the *remote* seam** — every remote-UI system went async-batched + optimistic-local. Resolution: **keep the Core API sync; make remoting a SEPARATE coarse state-sync transport adapter (snapshot + deltas + optimistic-local), not an async core API.**

**Steal-list:** Core shape ← Zed/CM6/Helix. Anti-pattern ← xi (no async boundary on read path). Coarse seam ← VS Code-remote/Jupyter. Remote transport ← Figma/Mosh/Fleet (optimistic-local + level-triggered delta-sync). Plugins/LSP ← LSP itself. Wire hygiene ← matklad/Tauri ("treat the wire as serialization, not your data model"; validate as a trust boundary).

---

## 9. DocumentModel decomposition path (🔶 the on-ramp to all of this)

1. Keep extracting coordinators — but reframe them as **domain state + pure sync transition functions + contained-deferral effects**, with a *thin* `@Published` projection in ViewerUI (not `@MainActor ObservableObject`s holding logic).
2. Introduce the **Command/Query/(level-triggered) subscription boundary**; `DocumentModel` becomes the Swift view-model (UI intent → Command; subscription → `@Published`).
3. Make deferred work **off-main by construction** (kills remaining stop-the-world).
4. Peel presentation concerns (zoom/theme/palette/alerts/view-nonces) **up** into the projection.

Blockers to a portable Core (from boundary audit): `ObservableObject`/`@Published` (Combine), `@MainActor` affinity, presentation concerns mixed in, 3 Combine-coupled Core types (`SessionsCoordinator`, `LSPNavigationStore`, `LSPDiagnosticsStore`). Logic is portable once observation mechanism + presentation are peeled off.

---

## 10. Provenance (so findings are traceable)
- Boundary + Linux audits: read-only workflow `wf_f0bbbe51` (validated).
- Detached-core research: workflow `wf_9d150fd4` (9 agents, web, verified).
- Sections 3.5–3.13, 5, 6: live design dialogue (this thread).
- A pre-launch audit (`wf_2db2b8e7`) is in flight; its perf/tech-debt/two-UI findings should append concrete DocumentModel offenders here when it lands.
