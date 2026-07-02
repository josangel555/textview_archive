# M1 plan — canvas-core document core (TSK-1344)

> ⚠️ **DRAFT — GATED ON THE M0 GO VERDICT (TSK-1355).** Slice tickets are filed when M1
> starts (per the milestone SOP). If M0 lands NO-GO, §S5/S7's boundary shape reworks first.
> Design source: `02-CORE-ENGINE.md` §2–§9 + `07-DSL-SPIKE.md` (parser lands with M1).

## Goal

Replace the M0 demo module with the REAL engine: flat record store + schemas + fence +
ops/inverses/revisions + DTCG tokens + static lint + deterministic lowering/patch plans +
migrations + canonical `.canvas` I/O + `source` ViewMode. Exit = UAT-M1
("the document survives everything", 06-MILESTONES-UAT §M1).

## Slices

- **S1 — record store.** `canvas/store.rs`: `Map<Id, Record>` arena, branded prefixed ids
  (caller-suppliable), atomic `place {parent, index}`, jittered fractional `IndexKey`
  (mint/between/rebalance), derived children index. proptest: order stable under arbitrary
  insert/move storms; no id reuse; place atomicity.
- **S2 — type registry + fence.** Per-type prop schemas/defaults/validators (frame/text/
  image/shape/component/embed/hole v1 set); the validation fence (schema, id-existence,
  cycle, caps, **op-target kind checks — discovered live in M0.S3: `setText` on a FRAME
  wipes its DOM subtree via textContent; the fence must reject kind-mismatched ops**) —
  typed errors, atomic batches. Fuzz target: op batches + doc files.
- **S3 — ops + inverses + revisions.** insert(partial+defaults)/update(dotted set+unset)/
  move/remove/batch; computed inverse per op; rev/baseRev conflict shape. proptest:
  `apply∘inverse = id`; idempotent supplied-id insert; fence never partially applies.
- **S4 — tokens.** DTCG-shaped store (`$value/$type`, brace aliases, deprecate-and-alias),
  resolution to CSS custom props, tier-2 steering lint hook.
- **S5 — lowering + patch plans.** Deterministic records→HTML emitter (per-type lowering,
  `data-cv-id`), op→minimal-DOM-patch plans (supersedes M0's mirror-the-op plan; the M0
  wire/applier shape carries over). Golden HTML fixtures as text diffs.
- **S6 — static lint v1.** Dangling refs (fail loud + suggestion), raw-literal-in-themeable
  nag, missing clamps on hug/fill, hole audit; lint rides every apply result.
- **S7 — migrations + `.canvas` I/O.** `{formatVersion, schema:{sequences}, records}` canonical
  sorted JSON; per-sequence up/down migrations run on load; corrupt record ⇒ typed error naming
  it. Round-trip: v0 fixture → migrate → canonical re-save. Serde streaming straight into the
  arena (no Value intermediate — §2c).
- **S8 — DSL parser core** (07-DSL-SPIKE §1 subset: insert/set/move/remove/batch statements +
  `#id`/`$token` addressing). Single-pass parse→ops, line-anchored errors, fuzz lane,
  `parse(render(doc)) == doc` property (canonical render lands here too — the projection
  seed). `each`/`let` scripting + `canvas_vocab` generation = M2.
- **S9 — Swift glue.** Codable mirrors (thin), document store/autosave/hot-exit, `.canvas`
  FileCategory + `source` ViewMode (JSON in CM6 — free), additive `TabSnapshot` fields.
  Host tests: open/save/relaunch-restore; UAT-M1 journey authored as the T6 script.

## Test matrix
cargo gate: S1–S8 (proptest + fuzz + golden fixtures) · host gate: S9 + mirrors ·
webview lane: patch-plan applier parity (S5 wire vs canvas.js — contract test) ·
T6: UAT-M1 journey. Perf: budgets tracked via the `perf_floor` ratchet
(bench.rs conventions — no clock in core, no criterion dep).

## Risks
fractional-index rebalance correctness (proptest storm) · msgpack↔Codable field-name skew
(contract fixtures shared Rust↔Swift) · ViewMode/TabSnapshot additive-safety (snapshot
round-trip tests) · M0 NO-GO rework of the boundary (gate) · scope creep into M2's agent
tools (the fence: M1 ends at the document core + source view; MCP surface is M2).
