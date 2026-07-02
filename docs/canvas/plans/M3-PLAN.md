# M3 — WYSIWYG (TSK-1346) — implementation plan

**Goal (05-ROADMAP §M3, 04-MODES §2, 06-MILESTONES-UAT §M3):** the canvas
becomes a REAL editable view in the app — a rendered lens for `.canvas` tabs
with direct manipulation: click-select with a visible overlay, drag-reorder
within the flow, inline text editing, and ⌘Z undo — every gesture lowering to
the SAME engine ops the agent uses (one write path, no UI side-doors).
Humans and agents co-edit the same revision stream.

**Lane dependencies (named up front, not discovered mid-slice):**
- **VM webview lane** — the bridge/DOM slices validate there. **TSK-1365**
  (WebContent-termination hardening) is now LOAD-BEARING; S1 absorbs its
  candidate fixes (shared webview per suite + pull-drain transport are
  already in-tree from M0). M1's VM-parity tail rides along: the first green
  VM run of the M3 suites ALSO closes TSK-1360's last tail.
- **T5 pixel lane** — overlay VISIBILITY must be pixel-proven (the WKWebView
  compositor-occlusion FALSE-GREEN trap: an overlay can be in the tree yet
  composite under the web surface — LESSONS/TSK-488 class). T5 needs the VM
  Screen-Recording grant (**TSK-1334, owner-gated**). Until granted: build
  the T5 tests self-skipping + validate the webview-lane half; the pixel
  half stays explicitly `review`-gated. Do NOT fake it with ImageRenderer.

## Architecture (one paragraph)

`CanvasTabController` (new, ViewerUI) owns the tab↔engine binding: it holds
the `CanvasOpenDocument` (store id ↔ tab id), mounts `CanvasWebViewHost` as
the tab's hostedView for ViewMode `.rendered`, pushes `setContent` on mount,
applies engine patches on every apply, and translates INBOUND edit intents
(click/drag/text) into `CanvasOp` batches against the tracked rev. Selection
is ENGINE-ADJACENT state (the controller's, not the doc's): the overlay is a
JS-side visual keyed by data-cv-id, driven by outbound `setSelection`
messages. Every mutation goes through `adapter.apply*` — the agent's exact
path — so human edits show up in `canvas_read` and agent edits paint live.

## Slices

### S1 — Rendered lens + tab binding (+ VM lane hardening)
- ViewMode: `.canvas` gains `.rendered` (source stays default until S7
  flips it); `hasTextRepresentation` unchanged; mode-switch arms route.
- `CanvasTabController`: store-doc-per-tab; mount host → `ready` →
  `setContent(html())`; re-lower on undo; teardown on tab close.
- TSK-1365 absorption: suites share ONE webview per class (setUp reuse),
  keep the M0 outbox/pull-drain transport; file the journal findings.
- Tests: host — controller state machine (mock host messages); VM webview —
  mount→contentSet→nodeCount on the REAL runtime.

### S2 — Bridge v2: edit intents + selection commands
- `CVInboundMessage` grows: `nodeClicked{id, modifiers}`, `textEdited{id,
  text}`, `dragEnded{id, parent, beforeId}`, `escapePressed`.
- `CVOutboundMessage` grows: `setSelection{ids}`, `clearSelection`,
  `setEditable{id, on}`.
- Codec tests host-side (pure); version window unchanged (v1 additive).

### S3 — JS runtime: hit-test, selection overlay, focus ring
- `canvas.js`: click hit-test to nearest `[data-cv-id]`; selection overlay
  as an absolutely-positioned box OVER the content (single overlay div,
  repositioned — not per-node borders, so geometry queries stay clean);
  Escape clears; overlay tracks reflow (ResizeObserver).
- VM webview tests: click → nodeClicked arrives; setSelection → overlay
  box's rect ≈ target's rect; reflow keeps them glued.

### S4 — Intents → ops: the write path + ⌘Z
- Controller maps: textEdited → `set #id text`; dragEnded → `move`;
  Delete key → `remove` (with selection); all via `applyDSL`/ops against
  the tracked rev; conflict → re-read + re-apply (the agent's own loop).
- ⌘Z routes to `canvas_undo` + full re-lower when the canvas lens has
  focus (the first-responder gate the editor already uses).
- Tests: host — intent→op mapping table (pure); VM — a click-edit-undo
  round trip through the real runtime.

### S5 — Inline text editing
- Double-click a text node → `setEditable(id, on)` → contenteditable;
  blur/Enter commits `textEdited`; Escape reverts. IME-safe basics
  (compositionend commits, no mid-composition ops).
- VM tests: edit → engine text updated (canvas_read shows it); revert path.

### S6 — Drag-reorder within the flow
- JS: HTML5 drag on selected node; drop indicator between siblings;
  dragEnded carries {parent, beforeId} from the drop slot.
- Engine: `move` with Before/After anchors (already exact from M1).
- VM tests: reorder → children() order changes + DOM order matches.

### S7 — UAT-M3 + pixel proof + default flip
- UAT-M3 (06 §M3): open a .canvas tab → click-select → overlay visible
  (T5 PIXELS, self-skipping until TSK-1334) → inline-edit → drag-reorder →
  ⌘Z chain → agent co-edit via canvas_apply lands live → save → reopen.
- Negative-control teeth: MDVNegativeControl switch that mis-anchors the
  overlay (`MDV_ENABLE_BROKEN_CANVAS_OVERLAY`) — the T5 test must go RED.
- Flip `.canvas` default lens to rendered; source stays one click away.

### S8 — Inspector + layers (title clauses)
- **Inspector**: a SwiftUI side panel for the current selection — kind, id,
  and its props (registry-driven rows: the allowed set for the kind, current
  values, token pickers for themeable slots); edits lower to `set`/`unset`
  ops through the same controller path. Read model = `canvas_read`'s data,
  not a parallel store.
- **Layers**: the document tree (children hierarchy from the engine),
  selection synced both ways (tree click → setSelection; canvas click →
  tree highlight); reorder via the tree lands as `move` ops.
- Host tests: registry-driven row derivation (pure); selection sync state
  machine. VM: tree-click selects on canvas (overlay moves).

## Budgets
- Intent→paint (click to overlay) p95 < 16ms local / < 30ms VM.
- Edit→paint (text commit to DOM update) p95 < 50ms (the M0 loop budget).
- Mount (open tab → contentSet) < 1s warm for a 1k-node doc.

## Risks / kill-criteria
- **TSK-1365 residual:** if the VM webview lane still kills WebContent after
  S1's absorption, escalate the ticket with the journal and validate S3/S5/S6
  locally (MDV_RUN_WEBVIEW_TESTS=1 on the host is the documented in-process
  fallback the M0 numbers came from) — do NOT silently skip VM validation.
- **Occlusion false-green:** overlay visibility claims ONLY via T5 pixels or
  explicitly-marked webview-DOM-geometry proxies; never ImageRenderer.
- **Kill-criterion (soft):** if intent→op→paint p95 blows 3× budget on the
  VM, stop and profile before building more gesture surface.

## Validation ladder
Host gate per slice (codec/controller/mapping are pure) → VM webview lane
per render slice (`MDV_WEBVIEW_FILTER` targeted, `webview` mode — NOT `all`)
→ T5 pixels for S7 (self-skipping until TSK-1334). Teeth on every guard;
the UAT is the milestone artifact.
