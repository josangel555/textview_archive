# Stage-B Swift-twin deletion — AGENT-DRIVEN validation/UAT plan (TSK-649)

**Owner resolutions (2026-07-04):**
1. **NO calendar soak** — single-user app; soak without traffic validates nothing.
2. **UAT = AGENT-DRIVEN UAT.** The agent builds AND validates on the VM; the human is
   NOT a verification gate. *"Human gate leads to bad agent behaviour of agents
   overclaiming which puts unnecessary burden on human."* Human involvement is the
   EXCEPTION: only for the AX-off-limits tier, a genuinely broken VM lane (file the
   blocker), or a true product call.

## The evidence ladder (per deleted twin — ALL agent-executed)

1. **Pre-deletion parity green (host)** — the engine's A/B parity + differential suites
   on current `main` (rust already default-ON; the twin is dead code in practice —
   deletion risk = losing the fallback + compile coupling, not behavior change).
2. **Post-deletion host gate** — `bash scripts/test-headless-gate.sh` green on the
   deletion commit (each engine = its own commit; smallest blast radius first, TSK-810
   order). Bench-only failures: TSK-1499 rule — re-run isolated before counting.
3. **VM suite slice** — `rsync` → `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password>
   MDV_RUN_WEBVIEW_TESTS=1 bash scripts/test-in-vm.sh all` (`all` rebuilds `dist/` —
   stale-dist trap). Scope = the engine's WV/T4/T5 + script-bus UAT suites. Verify
   dist freshness (`stat` vs `git log -1`) before trusting any failure.
4. **Agent-driven journey slice (T6-partial)** — the agent DRIVES the engine's user
   journey on the VM (script-bus verbs / `--script` T4 spawn / VM GUI lane +
   `screencapture` + Read the PNG for on-screen confirmation) and attaches the evidence
   (checks artifact + capture paths) to the ticket via `task_validate`. Pixel checks
   ride T5 where the lane grant allows; where a pixel/AX observable is blocked
   (TSK-1334), use the WV/T4 equivalent + capture evidence and NOTE the residual —
   never silently downgrade the claim.
5. **Release build** — `bash scripts/build-app.sh` + install; the owner gets a working
   app, not a verification task.

> **Safety note after deletion:** there is NO Swift fallback anymore — `RustCoreFallback`
> for that engine is gone. The no-panic fuzz lanes (TSK-1223/1232) + typed-error FFI are
> the remaining net. Any rust panic in a deleted-twin engine is a P0.

## Per-engine agent journey checks (mechanism tagged)

- **CSV** [WV/T4 + script-bus]: open ~100k-row CSV via verbs → sort/filter/edit/save
  round-trip asserts; convert commands output-diffed; `""` terminal row (TSK-1286 class)
  pinned in parity suite.
- **Hex** [T4 + script-bus]: open binary → scroll window → ASCII + hex-byte search verbs
  → match counts/positions asserted. (TSK-1423 unsaved-edit search is PRE-EXISTING —
  don't attribute to deletion.)
- **Find** [WV]: find-all highlight count (TSK-1140 behavior), regex + case modes,
  replace-one/all — `cmDispatch` asserts on the live WKWebView.
- **Fuzzy** [script-bus]: palette narrowing rank order pinned (prefix > substring >
  scattered) via the palette model harness.
- **Transcript** [T4]: open session `.jsonl` → event projection asserted; tail-follow
  appends live (the TSK-663 follow path).
- **Markdown** [WV + T5-if-granted]: frontmatter hidden (TSK-1433), tables, fenced
  highlight, mermaid host-div, TOC links jump (TSK-1430) — DOM asserts via
  `evaluateJavaScript`; pixel capture for the compositing classes.
- **cmEdit** [WV]: typed-edit batch → doc state asserts; undo/redo depth; multi-cursor
  single-application; large-file edit latency signposted (not wall-clock-asserted).
- **Highlight** (twin already deleted, TSK-854) [WV]: token-color asserts incl. Swift
  `//` + SCREAMING_CASE (TSK-1201 class).
- **Folds** (flipped ON @ c3ffbc45) [WV + script-bus]: fold/unfold via gutter + verbs in
  big JSON + Swift; fold-all/unfold-all; structural search returns.
- **Formula** (after TSK-1215 lands + flip) [script-bus + WV]: `=A1+B1` displays
  computed; formula edit box round-trips raw source; dependency edit recalcs;
  marker (TSK-1515) present-and-subtle via pixel/DOM check.

## Deletion order (smallest blast radius first, per roadmap/TSK-810)

1. `FuzzyMatcher` → 2. `FindEngine` → 3. `ClaudeLogParser` → 4. hex pair →
5. `CSVParser`/`CSVFilter` → 6. `CMEditApplier` → 7. markdown structural visitor →
8. `TreeSitterEngine` folds → 9. `FormulaEngine` (needs 1215 + flip).

Each step: delete + retarget twin-coupled tests + gate + VM/journey slice + own commit +
`task_validate` with the checks artifact. Self-validation bar per the 2026-06-07 policy:
evidence that would fail on regression — never "build is green".
