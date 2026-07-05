# Stateful-core spike — EditorSession, Tabs registry, DocumentModel projection (TSK-1508 → TSK-1117)

Status: spike/design (auto-approved lane). Author: claude-mdv, 2026-07-04.
Owner context: whole-core horizon committed ("do all", TSK-775); eviction policy resolved
(TSK-589: dirty never evicts; clean LRU under min(1–2 GB, 200 docs)); UAT = agent-driven
(docs/STAGE_B_DELETION_UAT_2026-07-04.md).

## Verdict

**Feasible as an 8-slice, shadow-first migration.** The load-bearing foundations already
exist in-tree; the missing pieces are a concrete `EditorSession` doc type, its FFI family,
and the Swift projection — plus two SUPERVISED cutover moments (save-path authority and the
DocumentModel/Tab read-swap), which are the only places the owner is needed.

## What exists vs what's missing

| Piece | State |
|---|---|
| Stateful UTF-16 doc + delta apply | ✅ `cm_edit.rs` `CmDoc.apply_delta` → `ChangedRegion`, FFI-wired (TSK-1124) |
| Multi-doc registry + eviction | ✅ `runtime.rs` `CoreRuntime<D>` + `DocId(u64)` + `EvictionBudget{max_bytes,max_count,ttl}` + `set_pinned` — matches the TSK-589 policy shape |
| UAF-safe handle registry | ✅ `ffi/handle.rs` never-reused tokens (TSK-541/583) |
| Transport seam (in-proc \| remote) | ✅ `CoreTransport`/`RemoteTransport`/`mdv-serve` (TSK-652/653/665) |
| Windowed-snapshot pattern | ✅ `CsvSession.snapshot_window_frame` — the template for large-doc reads |
| Concrete `EditorSession` in core | ❌ none (`session.rs` is CSV-only) |
| Core-owned dirty/saved-baseline/op-log | ❌ Swift `EditorBuffer.isDirty` + `Tab.isDirty` mirror |
| Swift projection over a core registry | ❌ `DocumentModel`/`TabCoordinator`/`EditorCoordinator` own it all |

## Contract design

- **`EditorSession`** (core) = `CmDoc` + saved-baseline hash (dirty = text-hash ≠ baseline,
  computed core-side) + append-only edit **op-log** (durability/local-history feed — NOT
  interactive undo) + meta (url, language, disk `(mtime,size)` baseline).
- **Registry:** `CoreRuntime<EditorSession>`; `DocId(u64)` becomes the public FFI id for the
  doc family: `doc.open / doc.apply_delta / doc.text / doc.window / doc.mark_saved /
  doc.set_pinned / doc.close`. Stale id → `DocNotFound`, never UB.
- **Mutation flow:** CM6 deltas (already `CmEdit`-shaped) → `doc.apply_delta`; verb/scripted
  edits apply core-side and emit `ChangedRegion` → one CM6 dispatch. External disk change →
  `doc.reload` diff → `ChangedRegion` → CM6.
- **Undo:** interactive undo/redo STAYS in CM6 (battle-tested, zero-latency, correct UX
  grouping). Core's op-log provides durability + local-history integration + audit. A
  blank-slate design would put undo core-side; re-implementing editor-grade undo grouping
  is high-risk/low-reward while CM6 is the interaction surface — revisit only if a
  non-CM6 editing front-end ships.
- **Dirty/eviction:** dirty ⇒ `set_pinned(true)` ⇒ NEVER evicted (owner rule, absolute);
  clean docs LRU-evict under `EvictionBudget(1.5 GB default, 200 docs)` — whichever binds
  first; invariant test: over-budget + all-dirty ⇒ zero evictions.
- **Save:** host does IO (sans-IO core) but writes **the text read from core** — the
  authority-of-record swap (S5, supervised).

## Buffer authority (the fork, resolved)

**Dual-doc; core is authority-of-record; CM6 is the interaction surface.** The keystroke
hot path is UNCHANGED (no per-keystroke FFI round-trip): CM6 applies locally, deltas mirror
into core on the existing debounced seam. Reads that matter (save, search-in-buffer, remote
viewers, WebUI live-share per TSK-1507) come from core. This resolves the TSK-1507
"separate editor vs live view" fork: a WebUI attaches to the same `DocId` session.

## Slices

| # | Slice | Lane |
|---|---|---|
| S1 | `EditorSession` in core: CmDoc+baseline+op-log+meta; unit+proptests (dirty-hash laws, op-log replay ≡ text) | autonomous |
| S2 | FFI family over `CoreRuntime<EditorSession>` + eviction policy constants (pinned-dirty invariant test) | autonomous |
| S3 | Swift `CoreDocStore` adapter + **SHADOW MODE** (`MDV_RUST_DOCSTORE=shadow`): every CM6 delta mirrors to core; differential text-equality assert per debounce tick — the parity net | autonomous |
| S4 | Hot-exit/session snapshots sourced from core text (shadow-verified against the Swift path) | autonomous |
| S5 | **Save-path authority swap** — writes read from core doc | **SUPERVISED ~1 h** |
| S6 | **DocumentModel/Tab projection cutover** — `Tab.isDirty`/title/tab-dots/footer read from the core registry; `TabCoordinator` becomes a view | **SUPERVISED ~1–2 h** |
| S7 | External-change reconciliation via core (`doc.reload` → `ChangedRegion` → CM6) | autonomous + supervised spot-check ~30 min |
| S8 | Remote parity: same session over `mdv-serve`; wasm-shape check on `EditorSession` | autonomous |

**Owner calendar ask (the TSK-1508 deliverable):** 2–3 supervised sessions, ≈2.5–3.5 h
total — Session A (S5) after S3/S4 run quiet in shadow for several days; Session B (S6);
optional C (S7 flip). Everything else lands autonomously behind gates with the shadow
differential as teeth.

## Non-goals

`DocumentModel`'s UI-shell state (palette/panel flags, feature VMs, prefs, sidebar) stays
Swift — the projection covers DOCUMENT state only (buffer/dirty/tabs/disk-state). No CRDT:
single writer per doc, N viewers; revisit if true concurrent editing ever becomes a goal.
LSP/terminal unchanged (own track).

## Risks / mitigations

- **Data-loss class** → shadow-first; the Swift path is deleted only after S6 validates
  (twin discipline); op-log replay test pins recovery.
- **UTF-16 offset skew CM6↔core** → S1 proptests + the existing cm_edit differential fuzz
  corpus extended with multi-delta sequences.
- **Eviction vs unsaved work** → the pinned-dirty invariant is a law-test, not a code path
  comment (owner rule is absolute).
- **Perf regression on the mirror seam** → the delta mirror rides the EXISTING debounce
  (TSK-1124 seam); PerfSignpost the apply path; no new keystroke-path work.
