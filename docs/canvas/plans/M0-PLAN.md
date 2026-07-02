# M0 plan — patch-loop risk spike (TSK-1343)

> Goal (06-MILESTONES-UAT §M0): prove **op → binary FFI → patch plan → JS DOM patch →
> geometry query back** hits budget, plus warm-cache park/re-attach, BEFORE any schema freeze.
> **Kill criterion:** patch loop can't hit budget ⇒ STOP, redesign the boundary before M1.
> M0 is a SPIKE: minimal schema (hardcoded demo doc), no fence, no DSL, no persistence —
> but the *conventions* used are the real ones so M1 inherits, not rewrites.

## Slices (each = implement → tests → gate → commit → board)

### S1 — `mdvcore-canvas` crate skeleton + patch-plan emitter  [cargo-gated]
- `rust-core/crates/canvas/` (new workspace member; added to `default-members` so the gate
  covers it and the staticlib can link it).
  - `demo.rs` — builds the hardcoded demo doc: **200 nodes** (frames/text, 3 levels deep),
    interned `u16` prop keys, arena `Vec<Node>` + `parent`/`index` — the §2c shape in
    miniature, no migrations/fence (M1).
  - `ops.rs` — `CanvasOp::SetText{id, text}` + `SetStyle{id, key, value}` ONLY (enough to
    exercise the loop); `apply(&mut Doc, ops) -> PatchPlan`.
  - `patch.rs` — `PatchPlan` = compact op list `{SetText(id, str), SetStyle(id, key, str)}`,
    serialized MessagePack into the existing `MdvBuf` frame (reuse `wire` conventions).
  - `lower.rs` — one-shot `initial_html(&Doc) -> String` (flat divs, `data-cv-id`, inline
    flex styles — throwaway-grade, enough to host 200 real DOM nodes).
- FFI (`crates/ffi`): 3 fns following house contract (ffi_guard + MdvStatus + out-params):
  `mdvcore_canvas_demo_open(out handle)` · `mdvcore_canvas_demo_html(handle, out MdvBuf)` ·
  `mdvcore_canvas_apply(handle, ops_msgpack_in, out patch_msgpack MdvBuf)` + free.
  ⚠️ `mdvcore.h` changes ⇒ **touch every referencing Swift file incl. Tests/** (SwiftPM
  staleness trap, CLAUDE.md).
- Tests: cargo — apply produces exact expected plan; msgpack round-trip; criterion micro-bench
  `apply+emit` (budget: **<100µs core-side** on the 200-node doc).
- Gate: `bash scripts/rust-core-gate.sh` (clippy no-panic + tests, --workspace --locked).

### S2 — Swift bridge + surface + vendored JS applier  [host-gated]
- `Sources/ViewerCore/CanvasBridge.swift` — `CVProtocol.currentVersion=1`,
  `CVInboundMessage`/`CVOutboundMessage` (apply / applied / geometry / geometryResult /
  ready), codec mirroring `CMBridgeCodec` (version-window decode). Pure, host-testable.
- `Sources/ViewerUI/Resources/canvas/canvas.html` + `canvas.js` — **plain hand-written JS,
  ~150 lines, NO npm build for M0** (the CM6-style build pipeline starts when the runtime
  grows in M2/M3): `window.cvDispatch` entry; applyPatch (SetText→textContent,
  SetStyle→style.setProperty) keyed by `data-cv-id`; `geometry(ids)` via
  getBoundingClientRect; `performance.now()` timestamps in replies for the E2E measurement.
- `Sources/ViewerUI/CanvasSurfaceView.swift` — minimal `NSViewRepresentable<WKWebView>`
  mirroring `CodeMirrorEditorView`'s `loadFileURL(canvas.html, allowingReadAccessTo: dir)` +
  script-message handler `mdvCanvas`; injects the initial HTML from S1.
- Tests: host — bridge codec round-trips (mirror `CodeMirrorBridgeTests` pattern); demo-doc
  FFI smoke (open/html/apply via the linked staticlib). Gate:
  `bash scripts/test-headless-gate.sh` (webview parts self-gate out of host).

### S3 — the E2E loop + warm cache + measurement  [webview-lane, VM]
- `WarmCanvasWebViewCache` (clone of the smallest existing warm cache) + park/re-attach.
- `Tests/ViewerUITests/CanvasPatchLoopWebViewTests.swift` (`MDV_RUN_WEBVIEW_TESTS=1`-gated,
  in-process WKWebView — the `EditorScrollRestoreWebViewTests` pattern):
  1. load demo (200 DOM nodes) → `ready`;
  2. apply SetText op → assert exactly that node's textContent changed (DOM query via
     evaluateJS) — **the patch loop proof**;
  3. geometry query returns sane boxes;
  4. park → re-attach → DOM + pending state intact (TSK-1046 class);
  5. **latency harness**: 50 sequential ops, collect core-time (signpost) + E2E op→paint
     (JS timestamps); report p50/p95 in the test log; ASSERT p95 < 50ms (budget p50 <16ms
     reported, not hard-asserted in v0 — machine variance).
- PerfSignpost around the FFI call + patch apply (measure-don't-guess directive).
- Run: rsync + `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> MDV_RUN_WEBVIEW_TESTS=1
  bash scripts/test-in-vm.sh` (targeted filter). Rust .a is HOST-built (VM has no cargo).

### S4 — verdict: budgets vs kill criterion  [report]
- Record measured numbers on TSK-1343 (checks artifact): core apply+emit, FFI round-trip,
  E2E op→paint p50/p95, park/re-attach correctness.
- **GO** (all budgets green) ⇒ M0 → fixed w/ evidence; M1 planning next.
- **NO-GO** ⇒ STOP per kill criterion; file the boundary-redesign ticket (options pre-listed:
  batch coalescing, shared-memory patch buffer, JS-side doc mirror) — do NOT start M1.

## Test matrix (ladder)
| Tier | What | Slice |
|---|---|---|
| cargo gate | ops/patch/msgpack tests + criterion bench + no-panic clippy | S1 |
| host headless gate | CVBridge codec + FFI smoke | S2 |
| webview lane (VM) | E2E patch loop, geometry, park/re-attach, latency harness | S3 |
| T5/T6 | none in M0 (no visual/UX claims made) | — |

## Risks
- **FFI perf surprise** (msgpack encode/decode dominating) → that's exactly what S4 measures;
  mitigation options pre-listed above.
- **WKWebView cold-start noise in latency numbers** → measure steady-state (warm) only;
  cold load reported separately.
- **`mdvcore.h` staleness SIGSEGV trap** → touch-all rule in S1, called out in the commit.
- **Scope creep into M1** (schema/fence/DSL) → M0 accepts hardcoded everything; any "real
  schema" urge is deferred to M1-PLAN.

## Perf budgets (from 02 §2c, M0 subset)
core apply+emit < 100µs · E2E op→paint p95 < 50ms (p50 target 16ms, reported) ·
demo load (FFI html + WKWebView render 200 nodes) < 1s warm.
