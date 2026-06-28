<!-- CLAUDE-HANDOFF v1 -->
# Handoff — VM 6.1.2 build fixed + DocumentModel SRP Format-slice; host surface drained  (2026-06-28)

**Session:** claude-mdv  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch:** `main` @ `b3251de2` (verify `git log -1`)

## Mission
Autonomous drain loop (5-min cron). Drain BACKLOG.md top-down by owner priority, then the board (`mcp__tasked__task_next`). Build inline, ONE item/firing: spike→implement→test→host-gate (`bash scripts/test-headless-gate.sh`)→commit per item; land rebase+ff; keep main gate-green. Fold doc updates into the item's commit. Never idle/stop.

## Current state — landed THIS session (most recent first)
- **TSK-1110 DocumentModel SRP split — Format slice** (`b3251de2`): carved the cohesive Pretty-print/Format group (8 members, ~76 lines) out of the 7692-line `DocumentModel.swift` into `DocumentModel+Format.swift` (the established forwarder-extension pattern); widened the shared `loadedText` helper `private`→internal. Behavior-identical; host gate green; core 7692→7616. Board: **progress** (epic continues — see Next).
- **TSK-1210 VM Swift 6.1.2 forward-compat build fix** (`e405a50a`, board=**review**): the RustCore `MsgPackValue` enum's `case map([(MsgPackValue, MsgPackValue)])` — a recursive TUPLE — tripped 6.1.2's type-checker ("circular reference"; 6.3 compiled it). Replaced with a named `MsgPackPair` struct (manual ==) across MessagePack/CoreClient/RemoteTransport + 12 test files. **VM-verified**: RustCore compiles on 6.1.2 (cycle gone). Forward-compat guard = nightly VM 6.1.2 build (VM-tier) → review is the agent ceiling.
- **TSK-1248** (`4eb49adf`, review): ⌘F defers to a focused control text field (no sidebar-filter hijack). Model-tested; render at review.
- **TSK-1294** (`e58adab3`): landing New-File temp-dir enumeration hang (12.9s→0.012s, user-facing perf). Host-tested.
- Earlier this session (DOM-patch TSK-838/1183, TSK-250 nav, the 5 owner dep-approvals: memchr/proptest/rusqlite-PM/wasm/fuzz) — all landed; full detail in `docs/AUTONOMOUS_PROGRESS.md`.

## Key finding — the host-completable surface is DRAINED
The clean, low-coupling, forwarder-style SRP slices (Format, FindBar, Editor forwarders) are DONE. The **remaining TSK-1110 slices are coupled to core private state → genuine access-boundary DESIGN, not mechanical verbatim moves** (documented in detail on the TSK-1110 board comment):
- Save-a-Copy: DONE — carved into `DocumentModel+SaveCopy.swift` (with the close-dirty forwarder, grouped as file-lifecycle) via a NEW vended `dirtyHexBytes(forTabID:)` accessor that keeps `hexDirtyBytes` private. THIS is the pattern for the remaining coupled slices: define the vended read accessor first, then move (no mutable-state widen).
- Editable-HEX is ~726 lines (owns hexDirtyBytes); Print/Export-PDF + Open-As… likely couple to rendered-webview/view-mode state (unverified).
The rest of BACKLOG's Next-50 is **render-VM / owner-gated / engine** (P1 features have host models mostly built; tails need a VM session or owner flip).

## Next action (post-compaction)
1. `git log -1` (expect `b3251de2`), `bash scripts/test-headless-gate.sh` is the gate; read BACKLOG.md + `mcp__tasked__task_next` (project `tasked`, agent `claude-mdv`).
2. Drain options, in order of cleanliness: (a) a DELIBERATE TSK-1110 design slice (define the vended accessor first, then move — fresh context helps here); (b) a P1 render-VM **host-model** increment (build the model, leave render at review); (c) the fixed-lane validation drain (validate fixed pure-logic with teeth → toward owner-close). The host surface is thin — expect design/render-VM/owner work, not easy mechanical wins.

## Gotchas / lessons (also in memory)
- **Background gate exit gotcha**: a backgrounded `gate; echo` reports the ECHO's exit (0) in the task-notification, NOT the gate's. Run the gate as the WHOLE backgrounded command (no trailing echo) so the notification exit IS the real rc; ALWAYS also grep the explicit `==> headless gate PASSED` + `tier enforcement: OK` markers before committing. (Caused a red-gate commit earlier this session.)
- **VM-lane commits bypass the host gate** → host-only ratchets (sleep-ratchet, cast/unwrap) can silently go red; run the host gate after VM-lane work too.
- **THIS handoff file**: keep it CURRENT. A stale HANDOFF.md (the 2026-06-27 one) misled this session's last compaction — I had to ignore it and re-fetch git state. Overwrite it at each real checkpoint.
- **The cron context does NOT reset between firings** (only at auto-compaction). "Defer to fresh context next firing" is a fiction unless a compaction happens — either do the work or genuinely checkpoint.

## Tracker (board `tasked`, agent `claude-mdv`, ids `TSK-###`)
- TSK-1210 → review (VM-6.1.2 fix). TSK-1110 → progress (Format slice landed; coupling spike documented for remaining slices). TSK-1248/1294 → done-ish (review/landed). Board: ~740 in-flight, ~410 await owner close; host-completable surface drained.

## How to resume
Assume zero memory of this conversation. `cd /Users/me/Documents/workspaces/claude/markdown_viewer`; `git log -1` (b3251de2); read this file + `docs/TASK_WORKFLOW.md` + `BACKLOG.md`; pull the next item via `mcp__tasked__task_next`. The clean mechanical SRP wins are spent — the next TSK-1110 slice is design work (accessor-first); or pivot to a render-VM host-model increment / fixed-lane validation. Gate every change with `bash scripts/test-headless-gate.sh` and verify the real rc + PASSED markers.
