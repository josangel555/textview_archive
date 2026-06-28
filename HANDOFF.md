<!-- CLAUDE-HANDOFF v1 -->
# Handoff — host high-value surface drained; data-safety + SRP slices landed; perf-sweep clean  (2026-06-28)

**Session:** claude-mdv  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch:** `main` @ `19c251b2` (verify `git log -1`)

## Mission
Autonomous drain loop (5-min cron). Drain BACKLOG → board (`mcp__tasked__task_next`/`task_list`). Build inline, ONE item/firing: spike→implement→test→host-gate (`bash scripts/test-headless-gate.sh`)→commit. Land rebase+ff; keep main gate-green. Fold doc updates into the item's commit. Never idle/stop.

## Landed THIS session (most recent first)
- **TSK-1269 slice 1** (`19c251b2`): `DocumentModel.reconcileExternalEdit(forTabID:url:) -> Outcome?` — host-testable decision wiring the orphaned `ExternalEditReconciler` 3-way merge (base=originalText/ours=text/theirs=disk; non-seeding `editorBuffers[id]`; nil→caller falls back to the prompt). 6 host tests. Board **progress** — slices 2/3 (buffer-replace seam + route refreshTab/watcher) are render→review.
- **TSK-1110 Save-a-Copy slice** (`83786b78`): carved Save-a-Copy + close-dirty into `DocumentModel+SaveCopy.swift` via a vended `dirtyHexBytes(forTabID:)` accessor (HEX state stays private). Core 7616→7523.
- **TSK-1110 Format slice** (`b3251de2`): Pretty-print/Format → `DocumentModel+Format.swift`.
- **TSK-1210** (`e405a50a`, review): VM Swift 6.1.2 build fix — recursive-tuple `MsgPackValue.map` → named `MsgPackPair` struct. VM-verified.
- **TSK-1248** (`4eb49adf`, review): ⌘F defers to a focused field. **TSK-1294** (`e58adab3`): landing temp-dir hang 12.9s→0.012s.
- Earlier: DOM-patch (TSK-838/1183), TSK-250 nav, the 5 dep-approvals. Detail in `docs/AUTONOMOUS_PROGRESS.md`.

## Key finding — host HIGH-VALUE surface EXHAUSTIVELY drained this session
Verified by scanning the whole actionable board (triaged ×11, reported ×45+) + deep-assessing candidates + a perf sweep. The host-completable veins are spent:
- **Orphaned data-safety backends** = the host-completable vein. TSK-1269 (ExternalEditReconciler) was the gem — done. TSK-1166 (DiskConflictResolver) is RENDER: `classify` is already the host decision + tested; a wrapper would be marginal/redundant (watcher already has the fingerprint). TSK-463 (LSP completion) / TSK-1176 (command history) are render (CM6/UI) — their host backends are built.
- **SRP split (TSK-1110)**: cheap stateless forwarder-slices DONE (Format, Save-a-Copy). Remaining sections own @Published/stored state (Print/Export, Editable-HEX, scroll, bookmarks) → extensions can't hold stored props → need track-2 (extract to a child @ObservableObject coordinator) = design-grade, fresh-context work.
- **Palette parity (TSK-1186)**: host verb-parity done+exhausted (11 verbs); remainder render/param-coupled.
- **Perf (TSK-837)**: test-speed sweep CLEAN — no new TSK-1294-style outlier; slowest classes are inherent IO/process (forkpty/subprocess/FSEvents/git); the 20s `TerminalForegroundBumpTests` is a LOAD FLAKE (0.054s isolated). TSK-1294's fix confirmed held. APP-latency half needs the VM perf harness.
- TSK-1165 flagged as a duplicate of TSK-1269 (owner to close).

## Next action (post-compaction — fresh context helps)
1. `git log -1` (expect `19c251b2`); host gate = `bash scripts/test-headless-gate.sh`.
2. The remaining work needs the OWNER, the VM, or fresh-context design — NOT easy mechanical host wins:
   - **track-2 SRP coordinators** (TSK-1110): extract a stateful section (Print/Export, bookmarks, scroll) to a child @ObservableObject the DocumentModel holds — design-grade, host-testable model + render rewire (review). Best fresh-context candidate.
   - **render-VM host-model increments** for P1 features (build the model, leave render at review): TSK-955 feeds, TSK-924 CSV multi-select, TSK-910 diff multi-line, TSK-1141 xlsx, etc.
   - **owner-gated** (task_park / surface, don't block): TSK-838 MDV_DOM_PATCH flip, the data-safety convergence decision (TSK-1269 vs TSK-1166), dep-approvals (TSK-835 nextest, TSK-852 CI-cache).
   - **rust-core P2 pool**: proptest growth / uncovered engines (gate via `bash scripts/rust-core-gate.sh`).

## Gotchas / lessons (also in memory)
- **Background gate exit gotcha**: a backgrounded `gate; echo` reports the ECHO's exit (0), NOT the gate's. Run the gate as the WHOLE backgrounded command (no trailing echo); ALWAYS grep `==> headless gate PASSED` + `tier enforcement: OK` before committing.
- **VM-lane commits bypass the host gate** → run the host gate after VM-lane work too.
- **Keep THIS file current** — a stale HANDOFF.md misled this session's compaction. Overwrite at each real checkpoint.
- **Cron context does NOT reset between firings** (only at auto-compaction). Don't "defer to fresh context next firing" — it's the same context until a compaction. Either do the work or genuinely checkpoint.
- **Measure don't guess** (perf): a slow test in the suite may be a LOAD FLAKE — confirm in isolation (`swift test --filter`) before treating it as a bug. APP-latency perf is VM-only.

## Tracker (board `tasked`, agent `claude-mdv`, ids `TSK-###`)
~740 in-flight, ~410 await owner close. This session advanced TSK-1294/1248/1210 (done-ish/review), TSK-1110 (progress, 2 slices), TSK-1269 (progress, slice 1), TSK-837 (perf-sweep recorded). The agent ceiling is review (render) / validated-with-teeth (pure logic) — the bottleneck is owner close + render/VM validation.

## How to resume
Zero memory of this conversation. `cd /Users/me/Documents/workspaces/claude/markdown_viewer`; `git log -1` (19c251b2); read this + `docs/TASK_WORKFLOW.md` + `BACKLOG.md`. The easy mechanical host wins are spent — pull from the live board (`task_list`/`task_next`), prefer a track-2 SRP coordinator or a render-VM host-model increment, gate with `bash scripts/test-headless-gate.sh` (verify the real rc + PASSED markers).
