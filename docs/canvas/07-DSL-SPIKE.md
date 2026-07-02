# Canvas · 07 — DSL spike (TSK-1350): the agent interface language

> **Detailed spike per owner directives (2026-07-01):** (1) agents must be able to learn the
> FULL vocabulary via MCP or a skill — optimize the language *for teachability*; (2) pair it
> with a hyper-optimized internal representation (see `02-CORE-ENGINE.md` §2c); (3) agents do
> focused work on reusable components, the SYSTEM handles replication/sync; (4) scripting —
> supported at authoring time, never inside the document. Status: **design complete, for owner
> review; no implementation.**

## 0. Design goals (ranked)

1. **Multi-turn incremental patching** — each turn touches a *portion*; cost ∝ edit size.
2. **Teachable in one small artifact** — the whole working vocabulary fits a cheat-sheet the
   agent can hold in context (~600–900 tokens); the long tail is discoverable on demand.
3. **Familiar surface forms** (LayoutGPT/meet-the-distribution): CSS-ish props, code-ish
   statements — minimal *new* syntax to teach at all.
4. **Deterministic + fenced**: every statement compiles to canonical ops; line-anchored errors;
   atomic batches; nothing bypasses the validation fence.
5. **Round-trippable**: any subtree renders to canonical DSL text and parses back identically —
   the basis of projection editing.

## 1. The grammar (v1 sketch — normative spec is the spike's implementation artifact)

Line-oriented; `#` starts an id-ref, `//` a comment; `{ }` = property block; `;` or newline
separates props; strings double-quoted with `\` escapes; bare words = identifiers/enums;
numbers default px, `%` allowed; `$path.to.token` = token ref; `none` = unset.

```text
// structure
insert <type|kitref> [#id] in <parent> [at <n> | before <ref> | after <ref>] { props }
set <ref> { prop: value; other: none }          // dotted paths ok: props.label, style.fill
move <ref> [to <parent>] [at <n> | before <ref> | after <ref>]
remove <ref>            copy <ref> [in <parent>] [as #id]
group <ref>, <ref>, … as stack|row|grid [#id]
name <ref> "Hero title"

// components (§4)
component kpi-card(label: string, value: string, delta: string = "") { …template… }
use kpi-card #k1 in #grid { label: "Revenue"; value: "$4.2M" }     // sugar for insert
detach #k1                                                          // fork instance → plain nodes

// timeline / behavior (deck & interact layers)
beat reveal at intro.end + 0.5s
animate #chart.opacity 0 -> 1 over 400ms ease out after beat:reveal
step #bullet2 reveal 2                       // deck fragment index
on #btn click -> goto pg:2
on #tab-b click -> set state.tab = "b"

// batches: a fenced block = ONE atomic op batch = one undo step
batch "Insert KPI row" { …statements… }
```

**Addressing:** `#id` (canonical), `%"Hero title"` (name — resolved to id at parse, ambiguity
is an error), `pg:2` (page). Write ops address concrete ids; pattern selectors (`frame.card`,
`in pg:2 text`) are **read/query-side only** — writes stay deterministic.

**Robust-to-LLM rules baked into the grammar:** trailing `;` tolerated · prop order free ·
unknown-but-well-formed lines rejected with did-you-mean (never skipped) · quotes required
only when a value contains whitespace/reserved chars · no significant indentation.

## 2. Vocabulary: single source of truth + discoverability (owner directive 1)

**The vocabulary is GENERATED, never hand-maintained.** The same per-type registry that drives
the fence, defaults, and lowering (`02` §3) emits every teaching artifact — so docs can't
drift from the validator:

| Artifact | Size | Delivery |
|---|---|---|
| **Cheat-sheet** — grammar + type list + common props + 6 examples | ~600–900 tok | Inline in the `canvas_apply`/`canvas_edit` MCP tool descriptions (always in context when the tools are) |
| **`canvas_vocab` tool** — sections: `grammar` · `types` · `type:<t>` (full props/defaults/enums) · `tokens` (the live theme tree) · `components` (kits in scope) · `verbs` · `examples:<task>` | ~100–400 tok/section | On-demand pull; versioned with the schema (`vocab@core:3`) |
| **Skill doc** (`canvas-authoring`) — the narrative guide + patterns + anti-patterns | ~2–4K tok | Generated at build from the registry; refreshed per release |
| **Teaching errors** — `unknown prop 'colour' on text — did you mean 'color'? (canvas_vocab type:text)` | free | Every fence rejection teaches the fix |

**Optimizing accordingly:** the grammar deliberately reuses CSS/Figma vocabulary so the
cheat-sheet only needs to teach *statements and addressing* (small), not property names (the
model already knows them). Budget test in the spike: a fresh agent given ONLY the cheat-sheet
must pass UAT-M2's authoring steps.

## 3. Projection editing (`canvas_edit`) — the read-modify-write path

1. `canvas_edit(selector)` renders the selected subtree as **canonical DSL text**: stable
   statement order (place order), registry-ordered props, defaults omitted, every node
   anchored `#id`, one `component`/`use` line per instance (never expanded inline).
2. The agent edits the text like a code region (its most-trained workflow).
3. Core **structurally diffs** old→new — the diff is keyed by `#id`, not by text:
   - same id, changed props → `set` (+ `unset` for `none`/removed lines)
   - id in old, absent in new → `remove`
   - new statement (no id / fresh id) → `insert` at its textual position → `place` computed
   - same id under a different parent/position → `move`
4. The resulting op batch goes through the fence like any other; carries `baseRev`.

**Guarantees (property-tested):** `parse(render(doc)) == doc` · `apply(diff(A, render(A)+ε))`
is exactly ε's ops · diff of an unedited projection = ∅ · renders are byte-stable across runs.

## 4. Component-focused work + system-owned replication/sync (owner directive 3)

**Focused editing.** `canvas_edit(component: kpi-card)` scopes the projection to the
*definition* — the agent's context holds ONLY the component (its param schema + template),
not the document. Lint runs component-scoped (unbound params, unused slots). This is the
"focused work" surface: small context, small diffs, high reuse.

**Sync is the engine's job, not the agent's:**
- **Within a document:** def-update ⇒ all instances re-expand as **one invertible op** (already
  core design). Instances are **closed** in v1 — they override *declared params only*; no
  structural overrides inside an instance (that's what keeps sync trivial and deterministic).
  The pressure valve is `detach` (fork to plain nodes, provenance-stamped). Slot-level
  overrides are the designed v2 extension.
- **Across documents — kits.** A kit = a `.canvas` document of kind `kit` holding defs (+
  tokens). A document `use kit "brand" pin <version|hash>` — imported defs are **vendored**
  (copied into the doc with provenance `{kit, version, hash}`) so files stay self-contained
  and exports work offline. When the kit changes, **the app detects hash drift and offers a
  per-document sync** (diff preview → one invertible op per doc). Manual-approve v1;
  policy knobs (auto-patch-level) later. Agents author *against* kits; replication/versioning/
  drift-detection is system machinery they never see.

## 5. Scripting (owner directive 4) — authoring-time macros, never document content

The line the research draws (PDF-vs-PostScript): **the document stays declarative data**;
scripts exist only at *authoring time*, expand to ops inside core, and are then gone.

```text
let quarters = ["Q1","Q2","Q3","Q4"]
each q, i in quarters {
  insert kpi-card in #grid { label: q; value: data.rev[i].usd }
}
if data.rev.rows > 8 { set #grid { cols: 4 } }
```

- Pure + deterministic: no I/O, no time, no randomness; expressions read only literals, `let`
  bindings, and document data blocks. Bounded: expansion caps (ops/batch, depth) — a script
  that expands past the cap is rejected whole.
- **What's recorded is the expanded op batch** (undo/events/audit see ops, not scripts).
- The runtime `repeat` node (§6 of `02`) stays the *live* data-driven mechanism; `each` is for
  one-shot generation the agent wants materialized as editable nodes. Guidance: bind when data
  is live, generate when the result should be hand-editable.
- Future (deliberately deferred): saving parameterized macros as kit assets ("authoring
  recipes"). Components remain the *runtime* reuse unit; macros the *authoring* reuse unit.

## 6. Wire & cost analysis (spike bench plan)

Benchmark on 3 realistic multi-turn transcripts (build status page · restyle deck · refactor
form): tokens per turn for DSL vs JSON-ops vs projection-edit; parse+apply latency; error
recovery (deliberately corrupted turns). Expected (to verify): DSL ≈ 3–6× fewer tokens than
JSON ops per equivalent edit (no key quoting/braces/envelope repetition); projection-edit wins
when >~5 edits cluster in one subtree. Ship criterion: DSL beats JSON ops on tokens AND on
first-try validity with only the cheat-sheet in context.

## 7. Implementation shape (in `canvas-core`; zero deps holds)

Hand-rolled recursive-descent lexer/parser (no parser-generator dep), interned identifiers,
single-pass parse→ops (no retained AST), line/col spans on every op for error anchoring;
fuzz target (parser = untrusted input) + property tests (§3 guarantees) + the golden
cheat-sheet fixture test (vocab artifacts regenerate byte-identically from the registry).

## 8. Risks & open edges

- **Grammar creep** — the DSL must not become a programming language; the §5 line (pure,
  bounded, authoring-only) is the fence. Review trigger: any proposal adding state or I/O.
- **Name addressing ambiguity** — `%name` errors on ambiguity by design; agents are steered
  to ids (queries always return ids).
- **Projection-diff surprises** — a reordered-but-unchanged line must diff to ∅ or a `move`,
  never remove+insert (id anchoring guarantees this; property-tested).
- **Two write surfaces** (DSL + JSON ops) — same fence, same ops, contract-tested for parity
  so neither drifts.
