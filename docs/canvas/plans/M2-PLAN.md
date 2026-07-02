# M2 — Agent Surface (TSK-1345) — implementation plan

**Goal (05-ROADMAP §M2, 07-DSL-SPIKE §4–6):** agents drive canvas documents
through the app's EXISTING MCP surface — discover the vocabulary, create/open
documents, author via DSL, read projections back, get lint, undo, save. No
pixels in this milestone (WYSIWYG + screenshot land in M3); everything here is
headless and host-testable.

**Foundation being reused (verified in-tree):**
- `Sources/ViewerCore/Automation/MCPToolCatalog.swift` — tool specs (name /
  description / JSON schema); the canvas tools append here.
- `Sources/ViewerCore/Automation/AutomationHost.swift` — the dispatch
  protocol; `Sources/ViewerUI/Automation/DocumentModel+AutomationHost.swift`
  is the live implementation. Canvas tool handlers follow the same pattern
  (protocol default = host-testable double; DocumentModel override = live).
- Engine surface (M1, all landed): `CanvasDocSession` / `CanvasDocAdapter` —
  applyDSL / apply(ops) / renderDSL / save / load / undo / html / lint riding
  every apply.

## Slices

### S1 — Registry-generated vocabulary (rust) — `canvas_vocab`
- `rust-core/crates/core/src/canvas/vocab.rs`: emit the FULL authoring
  vocabulary from the LIVE registries (never hand-written docs — the
  07-DSL-SPIKE rule): kinds + per-kind allowed props (name, value type,
  range/fence notes from `registry`), the 28-key prop table, token paths of
  the doc's store grouped tier-1/tier-2, DSL grammar cheat-sheet (element
  line, statements, values, anchors), and the error vocabulary
  (conflict/fence/store/idInUse/dsl).
- Output: compact agent-readable text (the DSL cheat-sheet form), plus a
  `{json:true}` variant for programmatic consumers.
- FFI: `mdvcore_canvas_vocab(handle, as_json, out_buf)` (handle-bound so the
  token section reflects the DOCUMENT's tokens, not just defaults).
- Tests: vocab lists every registry kind/prop (diff against
  `registry::allowed_names` programmatically — the vocab can never rot);
  token tiers present; teeth (drop a kind from the emitter → RED).

### S2 — Canvas document store (Swift) — lifecycle
- `Sources/ViewerCore/Canvas/CanvasDocumentStore.swift`: `@MainActor` registry
  of open `CanvasDocAdapter`s keyed by a stable doc id (the file URL when
  file-backed; `untitled-N` otherwise). create / open(path→`io::load` via
  adapter init(loading:)) / save(path) / close; rev bookkeeping surfaced.
- Autosave: file-backed docs write through the SAME safe-write path the text
  editor uses (no new persistence machinery — the .canvas source is text).
- Tests: lifecycle round trip; double-open dedupes to one handle; save writes
  canonical bytes (`io` golden byte-compat).

### S3 — MCP tools: `canvas_new` / `canvas_open` / `canvas_save` / `canvas_apply`
- Catalog entries + host handlers. `canvas_apply` accepts `{doc, baseRev,
  dsl}` (DSL is THE interface per Q2; a raw-ops JSON escape hatch can wait for
  demand) and returns `{rev, applied, minted, lint[], noop}` or the structured
  rejection (conflict carries currentRev; dsl carries the line-anchored
  teaching message VERBATIM — the close-the-loop rule).
- Tool descriptions embed the S1 cheat-sheet header + "call canvas_vocab for
  the full vocabulary" (07-DSL-SPIKE: vocabulary via MCP).
- Tests: through the REAL dispatch path (the AutomationHost double), per the
  existing MCP tool test pattern: happy build; conflict retry flow (stale
  baseRev → currentRev → retry succeeds); dsl teaching error surfaces
  verbatim; lint rides the response.

### S4 — MCP tools: `canvas_read` / `canvas_vocab` / `canvas_lint` / `canvas_undo`
- `canvas_read {doc, anchor?}`: whole-page DSL projection, or one subtree by
  `#anchor` (`dsl::render` on the anchored node — extend render() with a
  single-node entry). `{format:"json"}` returns the canonical JSON instead.
- `canvas_vocab {doc?}` → S1 output; `canvas_lint {doc}` → full-doc findings;
  `canvas_undo {doc}` → `{rev, undone}` + the shell re-reads.
- Tests: read-back equals `render_dsl`; anchored subtree slice; undo through
  the tool path restores (fingerprint via re-read).

### S5 — UAT-M2: the agent journey (06-MILESTONES-UAT §M2)
- One test driving ONLY the MCP tool surface end-to-end: `canvas_vocab` →
  `canvas_new` → `canvas_apply` (build, with a deliberate vocab error first —
  the teaching loop) → `canvas_read` (verify projection) → `canvas_apply`
  (edit w/ stale rev → conflict → retry) → `canvas_lint` → `canvas_undo` →
  `canvas_save` → reopen via `canvas_open` → `canvas_read` identical.
- Host-testable (no pixels). This is the milestone's acceptance gate.

## Budgets / risks / kill-criteria
- **Budget:** tool round-trip (dispatch → engine → response) p95 < 20ms on a
  1k-node doc (engine op cost is ~0.1ms; the budget is really the dispatch +
  projection path). Measured in the UAT with the M0-style printout.
- **Risk — doc addressing:** multi-doc `doc` ids vs the tab model. Mitigation:
  the store's ids are independent of tabs in M2 (a doc need not be open in a
  tab); M3 bridges them.
- **Risk — tool-count creep:** 8 new tools is the ceiling here; anything else
  waits for demand (Frugality).
- **Kill-criterion (soft):** if the S5 journey needs pixels to be meaningful,
  scope slipped into M3 — stop and re-plan.

## Validation ladder
Rust: cargo gate (S1). Swift: host headless gate (S2–S5, all host-testable —
this milestone deliberately needs NO VM lane). Teeth per slice; the UAT
doubles as the milestone's evidence artifact.
