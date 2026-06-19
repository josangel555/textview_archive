# What to cut from the board? — cut / dedup proposal (TSK-780)

**Homework doc — owner-decision required to act.** This is the survey + proposal
deliverable for **TSK-780 `[WISH][question][epic] What to cut from the board?`**.
It does NOT mutate the board lifecycle (that's the owner's call); it proposes a
concrete, ID-by-ID cut/dedup/merge list with rationale so the owner can approve in
one pass.

Board surveyed live via `mcp__tasked__task_list` on 2026-06-19 (project `tasked`,
markdown_viewer items only — foreign `agent:forge`/`sess-forge-*` rows excluded).

---

## TL;DR — the proposal in one screen

The board's actionable lanes hold **~134 markdown_viewer items** (93 `reported`
+ 35 `ack` + 6 `triaged` + ~19 `progress`). The cut/dedup opportunity is
**~30–40 items removable or collapsible** without losing any real intent:

| Bucket | Action | Count | Net board shrink |
|---|---|---|---|
| A. Stale-lease `progress` zombies | reset lease / re-triage (NOT silent-cut) | ~11 | 0 (re-home) |
| B. True duplicates | dismiss the dup, keep the canonical | ~5 pairs | −5 |
| C. Over-decomposed clusters | merge children under parent epic | ~3 clusters (~9 items) | −6 |
| D. Already-decided `wontdo`/parked, still showing | confirm-close | ~4 | −4 |
| E. Aspirational `very-large` never-starting | demote to a single "icebox" epic | ~8 | −7 |
| F. Internal `tasked`-tool tasks mixed into the board | move to `internal` project | ~5 | −5 (off this board) |

**Net: ~27 fewer rows** on the markdown_viewer board, none of them losing intent.

---

## A. Stale-lease `progress` zombies — RE-HOME, don't cut

These sit in `progress` with a `claimed_by` lease that **expired weeks ago** (lease
timestamps in the `1780.7xx–1780.9xx` range = early-to-mid June; "now" is
`~1781.9xx`). They were claimed by an agent run that died mid-work and never
released. They masquerade as "in flight" but nothing is moving.

| ID | Title | Lease | Verdict |
|---|---|---|---|
| TSK-276 | `[BACKLOG] Debugger` | expired | re-triage; also the #NNN-trap ticket (CLAUDE.md) — verify topic before any close |
| TSK-279 | `[BACKLOG] LSP MCP` | expired | re-triage; #NNN-trap ticket — overlaps TSK-781 (LSP strategy) + TSK-943 (share LSP w/ Claude) |
| TSK-293 | `[BACKLOG] Encryption` | expired | re-triage; no design exists — likely → icebox (bucket E) |
| TSK-296 | `[BACKLOG] Markdown` | expired | **vague stub** — title is one word; either restate concretely or cut |
| TSK-298 | `[BACKLOG] Java` | expired | **vague stub** — same; restate or cut |
| TSK-326 | `[PARTIAL] Command palette via '>' omni-search` | expired | #NNN-trap ticket (CLAUDE.md names it) — verify, re-triage |
| TSK-364 | `[PARTIAL] Invisibles too grey` | expired | **DUP of TSK-359** (both grey-invisibles); 359 already `wontdo` (NSLayoutManager subclass banned). Cut 364. |
| TSK-373 | `[PARTIAL] New → Code review / Agent session / Project view` | expired | re-triage; overlaps TSK-537 (code review epic) |
| TSK-375 | `[PARTIAL] Plugin support [Crux URL, pipeline monitor, CR widget]` | expired | re-triage; overlaps TSK-782 (plugin expansion) |
| TSK-376 | `[PARTIAL] Fully hackable/controllable/automatable` | expired | re-triage; overlaps TSK-799 (scripting) + TSK-376 is a theme not a task |
| TSK-377 | `[PARTIAL] Illustrations` | expired | **vague stub** — restate or cut |

**Recommended action:** `task_unblock`/lease-reset all 11 back to `reported`/`ack`
so they re-enter the normal queue rather than looking falsely "claimed." Then
apply the per-row verdict (cut the 3 vague stubs + the 1 dup, re-triage the rest).
Leaving expired leases in `progress` is the single biggest source of the board's
"~20 progress, mostly stale" line in `CURATED_TASKS_2026-06-19.md`.

---

## B. True duplicates — dismiss the dup, keep the canonical

Pairs where two rows describe **the same work**, not two facets of it.

1. **TSK-591 `[UI-BUG][perf] Mouse-over on the file nav is very laggy`** (progress,
   stale lease, `live-validation`) **vs TSK-892 `[INTAKE-0614][PERF][filenav]
   File-tree hover is slow`** (reported, confidence high).
   → Same bug, same subsystem. **Keep TSK-892** (fresher INTAKE-0614 framing, clean
   `reported` state, high confidence; it's in the in-flight drain wave). **Cut
   TSK-591** (stale lease) — fold its `live-validation` note into 892.

2. **TSK-364 `[PARTIAL] Invisibles too grey`** vs **TSK-359 `[PARTIAL] Special
   chars appear grey`** → identical symptom + identical blocker (read-only
   NSTextView grey invisibles; fix needs the banned NSLayoutManager subclass).
   359 is already `wontdo` with the full rationale recorded. **Cut TSK-364.**

3. **TSK-277 `Java debugger (JDWP/DAP)`** + **TSK-278 `Chrome DevTools-protocol
   debugger`** vs **TSK-276 `[BACKLOG] Debugger`** → 276 is the generic umbrella;
   277/278 are the two concrete protocol arms. Not true dups, but **276 should
   become the parent** of 277/278 (or be cut as a redundant umbrella once 277/278
   carry the work). Recommend: cut the generic 276, keep the two concrete arms.

4. **TSK-256 `[PORT][WEB] Markdown rendered view`** vs **TSK-296 `[BACKLOG]
   Markdown`** → 296 is a one-word stub; 256 is the concrete web-port rendered-MD
   item. If 296's intent is the web rendered view, it's a dup of 256 → **cut 296.**
   (If 296 means something else, it must be restated — it currently carries no
   actionable content.)

5. **TSK-320 `[BACKLOG] Photo editor`** vs **TSK-380 `[PARTIAL] Mini Paint —
   Raster, Vector image editor`** vs the **PAINT cluster TSK-403/404/405/406**
   (canvas / color-picker / flood-fill / selection). → 320 and 380 are the same
   feature stated twice; 403–406 are 380's concrete sub-tasks. **Keep TSK-380** as
   the parent, **cut TSK-320** (duplicate), **re-parent 403–406 under 380.**

---

## C. Over-decomposed clusters — merge children under a parent epic

Where one feature got filed as 3+ sibling rows that will be implemented together
in one slice. Keeping them separate inflates the count and fragments review.

1. **Agent-diff-review cluster** (all already children of TSK-687):
   TSK-940 (review agent diffs) · TSK-941 (approve/reject) · TSK-942 (select-lines →
   reference/comment). These are one feature ("in-app agent-diff review"). Parenting
   is already correct — recommend **collapse 940/941/942 into a single TSK-940**
   "agent-diff review surface" with the other two as acceptance criteria, freeing 2 rows.

2. **Agent-services duplication:** TSK-697 `Agent Services suite — semantic/LSP
   search, global search, refactor, test runner, code review` vs TSK-699 `Agent
   Services — what helps an agent work on a project`. 699 is a vaguer restatement of
   697. **Merge 699 into 697.** Also overlaps TSK-693 (see/solve tasks, worktrees,
   review) — consider 697 as the umbrella.

3. **Plugin epics** are spread across **TSK-772 (SQLite-browser-style plugins),
   TSK-773 (plugins expose MCP), TSK-777 (Plugin Dev Kit + AI skill), TSK-782
   (office-integration plugin expansion), TSK-779 (decompose-into-plugins question),
   TSK-338 (merge plugins), TSK-375 (plugin support stub).** That's 7 plugin rows.
   Recommend a single **"Plugins v2" parent epic** with 772/773/777/782 as slices
   and 338/375 folded in. (779 is the design-question that gates them — keep it
   separate as the parked decision.)

---

## D. Already-decided `wontdo` / parked still cluttering the actionable view

These have a recorded decision but still surface. Confirm-close so they leave the
working set.

- **TSK-359** (`wontdo`, grey invisibles) — keep `wontdo`, just confirm it's off the
  actionable pool (and cut its dup 364 per bucket B).
- **TSK-103/102/104** (`wontdo`, `sess-forge-*`) — these are **foreign forge items**
  already dismissed; they should never have been in a markdown_viewer survey. No
  action on our side (correctly `wontdo` + foreign), noted only so the owner knows
  they're not ours.
- **The 5 parked design-Qs** (TSK-787 hybrid-test, 781 LSP, 779 plugins-Tier-D,
  775 migration, 788 T5-coverage) — these are `triaged`+`waiting:human` with a
  spike done. They're not cuttable (they're real decisions) but they should be
  grouped into ONE "decisions needed" owner queue rather than counted as backlog.

---

## E. Aspirational `very-large` that will never start as filed → ICEBOX

`ack`/`reported` items tagged `very-large` or `P7/P8` with no design, no slice, no
realistic near-term path. Not "cut the idea" — **demote to a single tracked
"Icebox" epic** (or `prio:3` park) so they stop padding the active count:

- TSK-689 `Integrate with PinBoard` (very-large)
- TSK-694 `Log-pattern clustering` (epic, P7)
- TSK-695 `Credential recognition/obfuscation` (epic, P7)
- TSK-700 `Inter-person + agent collaboration` (very-large)
- TSK-702 `Mac's own intelligence for editing/completion` (epic, P7)
- TSK-774 `Music (unspecified)` (very-large — title literally says "unspecified")
- TSK-687/693/699 `agent-integration epics` (P6/P7 — overlap, see bucket C)
- TSK-369/370 `Linux/Windows/Powershell port` (P3 — explicitly future-proofing, not now)

These 8-ish stay as ideas under one icebox parent; the board shows 1 row, not 8.
**TSK-774 in particular** ("Music (unspecified)") is the strongest pure-cut
candidate — it has zero actionable content.

---

## F. Internal `tasked`-tool tasks polluting the markdown_viewer board

Several rows are about the **tasked tracker itself**, not the markdown_viewer app.
Per CLAUDE.md (`docs/TRACKER_FEEDBACK.md`, file tracker feedback as INT-### in the
`internal` project), these belong on a different board:

- TSK-441 `Tests + adversarial review across v0.2–v0.5`
- TSK-442 `check/CI validation path (validated_by=check:<id>)`
- TSK-443 `Deploy-snapshot: stop launchd auto-deploy footgun`
- TSK-444 `delete-empty-project (remove stray zz_probe)`
- TSK-445 `Enforce implementing-commit provenance`

**Recommended action:** move these 5 to the `internal` project (or dismiss if
already handled). They're not markdown_viewer work and shouldn't count against the
app backlog.

---

## What NOT to cut (explicitly keep)

- **All `[SECURITY]`/`[BUG]` H/M/L audit findings** (TSK-969..1015) — concrete,
  high-confidence, host-testable. These are the highest-value backlog; keep every one.
- **The perf cluster** (839, 890, 891, 892, 971, 972, 973, 984, 985, 986, 996) —
  measured, real, felt-by-owner.
- **The 5 parked design decisions** — real owner forks, not cuttable.
- **Dep-gated items** (399, 584/585/587, 835, 851, 852, 897, 1014) — blocked on
  owner approval, not dead; keep parked.

---

## Recommended one-pass owner actions (copy/paste-able)

1. **Cut (dismiss) — 5 pure duplicates/stubs:** TSK-364, TSK-591, TSK-320,
   TSK-296 (if it means web-MD), TSK-774.
2. **Re-home — 11 stale-lease zombies:** reset leases on TSK-276/279/293/296/298/
   326/364/373/375/376/377 → `reported`/`ack` (then apply cuts above).
3. **Merge children — 2 clusters:** fold 941/942 into 940; fold 699 into 697.
4. **Re-parent — PAINT + plugins:** 403–406 under 380; 772/773/777/782/338/375
   under a "Plugins v2" parent.
5. **Icebox — ~8 aspirational:** one parent epic over 689/694/695/700/702/774/
   369/370.
6. **Off-board — 5 tracker-internal:** move 441–445 to the `internal` project.

**Estimated active-board shrink: ~134 → ~107 actionable rows** (−27), with zero
loss of real intent — every cut is a duplicate, a vague stub, an
already-decided item, or a re-home.

---

*Survey method: `mcp__tasked__task_list` over `reported`/`ack`/`triaged`/`progress`
lanes (project `tasked`), cross-checked against `docs/CURATED_TASKS_2026-06-19.md`
lane counts and CLAUDE.md's recorded #NNN-trap / dup notes. Foreign forge rows
excluded. No board lifecycle was mutated — owner approval gates the actions above.*
