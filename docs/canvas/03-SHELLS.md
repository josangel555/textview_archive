# Canvas · 03 — Shells: JS runtime, Swift host, bridge, security

> Deliberately thin. Everything semantic lives in `canvas-core` (`02-CORE-ENGINE.md`); the
> shells do I/O, pixels, and interaction. Every piece below reuses a proven in-app pattern —
> verified against the code 2026-07-01.

## 1. JS runtime shell (vendored, CM6-style)

Built like CM6/mermaid: `scripts/canvas-build/` (npm at build time only), IIFE vendored into
`Sources/ViewerUI/Resources/canvas/`, integrity-tested per `VENDOR.md`. Responsibilities:

- **Patch applier.** Applies core-emitted patch plans to the DOM keyed by `data-cv-id`. Dumb by
  design — no semantics, no innerHTML rewrites. Full re-project = recovery path only.
- **Measurement services.** `geometry(ids)` (resolved border boxes, overflow flags),
  `hitTest(x,y)`, measured lint (overflow/contrast/tap-target) — results returned as data to
  core/agent. This is the *only* home of pixel truth besides T5.
- **Direct manipulation.** Selection model, drag/resize handles, snap/guides, marquee, inline
  text editing (contenteditable scoped to text nodes). Gestures emit **ops** through the same
  fence as the agent — the DOM is never mutated as truth. Ephemeral state (selection, hover,
  drag) lives in the runtime store, *outside* the document (Flutter three-trees lesson).
- **Player.** Interprets timelines (`{a,k}` → WAAPI `KeyframeEffect`s; compositor-threaded),
  steps/fragments, morph transition plans (FLIP), behaviors/state machines, scroll-driven
  timeline bindings (scrollytelling). The same player ships inside exported standalone HTML.
- **Snapshot.** PNG of surface/page/node via the runtime (canvas/`drawImage` path) — headless,
  **no Screen-Recording TCC**, size-capped.

## 2. WKWebView host + bridge

- `CanvasSurfaceView` mirrors `CodeMirrorEditorView`: bundle-hosted `canvas.html` via
  `loadFileURL`, shared process pool, **warm cache (`WarmCanvasWebViewCache`) from day one** —
  park/re-attach so runtime state survives tab/session switches (the TSK-1046 class, solved by
  adoption not re-discovery).
- `CanvasBridge.swift` (ViewerCore): versioned envelope `{v, type, replyId?}`, single
  `window.cvDispatch` entry, `WKScriptMessageHandler` inbound, requestReply completion pattern —
  the exact CM6 bridge discipline, host-testable pure.
- Perf budget: op→paint < ~16ms typical; PerfSignpost from the first slice (measure-don't-guess).

## 3. Swift host shell

- **Files/persistence:** `.canvas` documents (canonical JSON from core); autosave + hot-exit
  spill; local-history checkpoints per N ops; session snapshot carries viewport/selection
  (additive `TabSnapshot` fields). File on disk is the truth — agent- and git-friendly.
- **Undo stack UI:** ⌘Z over core-provided inverse ops; author labels in timeline
  ("Insert KPI row (agent)"). Shared human/agent history.
- **SwiftUI chrome (native):** inspector (selected node props/tokens), layers/outline sidebar
  section (`SidebarSectionRegistry`), insert palette, page/step strip for decks. In-webview:
  handles/guides/inline-text only (hit-testing/IME need it). **Occlusion hazard is known**
  (LESSONS compositor trap): floating chrome over the WebView gets `compositingGroup().zIndex(1)`
  + a T5 negative-control test from the first slice.
- **ViewModes:** `.canvas` FileCategory; `canvas` (WYSIWYG) · `source` (JSON in CM6, free) ·
  `preview` (read-only render). Additive `ViewMode` case, snapshot-safe.

## 4. Agent surface (MCP + verbs)

`MCPToolCatalog` + `AutomationHost` pattern (all host-testable with a fake host):

| Tool | Contract |
|---|---|
| `canvas_create` / `canvas_open` / `canvas_list` | New/open/list (path-jailed). Returns doc + root ids. |
| `canvas_apply` | `{baseRev, ops[]}` → `{rev, staticLint[]}`. **The** write tool. |
| `canvas_query` | selector → compact projected records (+geometry when measured). |
| `canvas_lint` | merged static+measured report, provenance-tagged. |
| `canvas_timeline_state` | declarative "what's visible at step/beat" (verify before pixels). |
| `canvas_snapshot` | PNG page/node/surface (capped). Last resort, most expensive tier. |
| `canvas_export` | standalone HTML / PDF / PNG to a jailed path. |
| `canvas_events` | op feed since rev N (human-edit awareness). |

Feedback ladder (cheap→dear): **query → static lint → timeline state → measured lint →
snapshot**. Lint rides along on every apply so problems surface unasked. Same catalog exposed
as script verbs (group `canvas`) for `--script`/UAT and `textview://canvas?path=…`.

**Precedent note:** these are the app's first content-*writing* automation tools. Policy:
writes only through the op fence, only to `.canvas` docs; visible "agent editing" tab
indicator; `canvas_events` is the audit trail; per-document human grants deliberately NOT
required (Q7) — friction would kill the core loop.

## 5. Security envelope

1. Trusted-mode CSP (the audited `HTMLDocumentPolicy` posture — note: lives in
   `Sources/ViewerCore/`): our vendored runtime only, `connect-src 'none'`, no external
   subresources, navigation through the existing policy allowlist. Documents cannot phone home.
2. **Documents are data.** Behaviors = closed interpreted verbs; the only code-bearing node is
   `embed` — v1 = sanitized HTML/CSS in a sandboxed iframe (separate origin, no bridge);
   script-bearing embeds deferred to an explicit owner decision (Q5).
3. Op fence on every apply regardless of author; resource caps (node count, asset size, batch
   size, snapshot pixels) fail as typed errors.
4. Path jail on all tools (`validatedExistingURL`-class); asset names sanitized
   WalkthroughStore-style. Assets: single-file base64 to ~2 MB, sidecar dir beyond (Q6).

## 6. Test allocation (per house tiers)

- **Host gate:** core (cargo) + bridge envelope round-trips + MCP tools over fake host +
  Codable mirrors + persistence.
- **Webview lane** (`MDV_RUN_WEBVIEW_TESTS=1`, VM): patch-applier correctness (apply ops →
  DOM asserts via the reply bridge), measurement answers, player/fragment/morph stepping.
- **T5 pixel (VM):** handles visible, drag moves pixels, chrome-over-WebView occlusion — each
  with a negative-control switch (TSK-1134 convention). **T6:** journey scripts via the
  `canvas` verb group.
