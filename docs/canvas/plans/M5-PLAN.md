# M5 — UI-Design mode, Tier 1 (TSK-1351) — implementation plan

**Goal (04-MODES §1–2, 05-ROADMAP §M5; the owner's Q1: the mode that
validates assumptions earliest):** the first MODE — a PRESET over the shared
core, never a fork. UI-Design mode gives the Claude-Design-class workflow a
shape: artboard-framed documents (desktop/mobile viewports), a
design-forward starting template (kit + tokens pre-imported), mode-aware
export flavors, and the responsive check. One core, many modes — M5 proves
the modes layer stays THIN (the kill criterion below makes that executable).

## Architecture (the thin-mode law)

A mode is DATA, not machinery: (a) a `mode.<name>` document token (persisted
by io, visible in vocab — the same trick as the kit pin); (b) a NEW-DOCUMENT
TEMPLATE (a DSL fragment applied at create); (c) presentation presets the
existing surfaces read (artboard chrome in the lowering; panel defaults in
the tab controller); (d) export flavors. NO new record kinds, NO engine
branches on mode — if a slice needs one, the design is wrong (kill).

## Slices

### S1 — mode infrastructure + the UI-Design template
- `canvas_new {mode?: "ui-design", template?: "desktop"|"mobile"|"both"}`:
  seeds the mode token, imports the starter kit, applies the template DSL
  (artboard frames below). Plain `canvas_new` unchanged.
- The mode token drives NOTHING engine-side (the thin-mode law) — it exists
  for shells/tools to read.
- Tests: template creates the artboards + kit + token; plain new untouched;
  the mode rides save/load (io already covers tokens — pin it).

### S2 — artboards (rust, thin)
- An artboard IS a frame with `role=artboard`, fixed `minW/maxW` (1280
  desktop / 390 mobile presets in the template) + a `note`-style label.
- Lowering: `role=artboard` frames get chrome — a label strip (the note
  text) + an outline + page-canvas background (all token-colored, all via
  the EXISTING props/roles — zero new kinds; the `role` prop already
  exists).
- Lint: content wider than its artboard (the measured overflow stage
  already catches it — verify with an artboard fixture, no new rule).
- Tests: chrome renders; two artboards side by side; overflow-in-artboard
  flagged by the EXISTING measured stage.

### S3 — export flavors
- `canvas_export {flavor?: "standalone"|"fragment"}`: standalone = today's
  B0 (theme + page); FRAGMENT = one artboard's subtree without the theme
  block, custom-props inlined as literals (resolve through the token store)
  — embeddable in an existing site. `{artboard?: "#id"}` picks which.
- Tests: fragment inlines literals (no var()), scopes to the artboard,
  standalone unchanged (golden-adjacent asserts).

### S4 — the mode-aware shell (Swift, lean Tier 1)
- The rendered lens reads the mode token: UI-Design docs open with layers +
  inspector visible and a KIT STRIP (a thin insert palette listing the six
  kit components; click = `use` at the selection point — through the
  controller's op path like everything else).
- Mode-aware empty state: "New UI design" seeds via the S1 template.
- Tests: host — kit-strip derivation from the store's definitions + the
  insert action lands an op; controller mode detection.

### S5 — UAT-M5: the designer journey
- new(mode: ui-design, both artboards) → kit-strip insert → inspector prop
  edit → agent co-edit (canvas_apply into the same doc) → measured lint per
  artboard (responsive check: content overflowing MOBILE but not DESKTOP is
  the fixture) → export standalone + fragment → reopen → identical.
- Host + local webview lanes (the standing contingency).

## Budgets
- Template apply (mode new): < 50ms engine-side (it's ~20 ops + kit).
- Fragment export of a 500-node artboard: < 50ms (a lower + token resolve).

## Risks / kill-criteria
- **THE THIN-MODE KILL:** any slice that needs an engine branch on the mode
  token, a new record kind, or mode-specific op semantics = STOP; the modes
  layer is leaking into the core and the design needs the owner.
- **Panel creep:** the kit strip is Tier 1's ONLY new chrome; palettes/
  asset browsers/multi-doc libraries wait for demand.
- The identity-morph transition feature stays M6 (it's presentation-first).

## Validation ladder
Rust: cargo gate (S1-S3 engine bits). Swift: host gate (S4) + local webview
for render checks (standing contingency). The UAT is the milestone artifact.
