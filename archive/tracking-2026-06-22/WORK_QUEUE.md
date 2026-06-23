# Work Queue — RECONCILED & SUPERSEDED 2026-06-19

> **This file is no longer the active queue.** It was reconciled on **2026-06-19**
> against the live `tasked` board (the system of record for state) and split into two
> fresh documents. Drain from those, not from here.

## ➡️ Active list (drain this top-down)

**`docs/CURATED_TASKS_2026-06-19.md`**

The brand-new go-forward list: every UNDONE / incomplete / untouched task, reconciled
and categorized (Bugs / Perf / Features / Tech-debt / Security / Rust-core / Owner-gated),
ranked by value × tractability within each group, each with a one-line why and a flag
(`[in-flight]`, `[owner-gated: …]`, `[needs-VM-trace]`, `[needs-VM-render]`,
`[host-buildable]`). A "Top 10 next" sits at the end.

## 📦 Completed archive

**`docs/COMPLETED_ARCHIVE_2026-06-19.md`**

Every DONE item (board state `fixed` / `review` / `validated` / `done`), grouped by area
with recorded SHAs. ~430 markdown_viewer tasks — including the ~33-item "ultracode" wave
just shipped to `review`/`fixed`.

## 🚧 In flight (2026-06-18 → in progress)

Four workflows are implementing right now; their tickets are flagged `[in-flight]` in the
active list — pick around them:
- **LSP epic TSK-963** (productionalize discovery/visibility/integration) + slices
- **tmux epic TSK-964** (full `tmux -CC` control-mode native integration)
- **Security-fix wave TSK-965 … TSK-1015** (the 2026-06-18 adversarial review —
  `docs/research/adversarial-review-2026-06-18/FINAL.md`)
- **"the-30"** — remaining `docs/NEXT_30_TASKS_2026-06-18.md` items

## Notes

- `docs/NEXT_30_TASKS_2026-06-18.md` is **folded in and superseded** by
  `docs/CURATED_TASKS_2026-06-19.md` — don't drain it separately.
- The `tasked` board (`http://localhost:8787/mcp`, agent `claude-mdv`, ids `TSK-###`)
  remains the **system of record** for lifecycle state. These docs are the priority
  SELECTOR; the board is the live per-item state.
- Foreign projects (wx-globe, forge, tasked-tool-dev) and `wontdo`/dismissed tickets are
  excluded from both new docs.
